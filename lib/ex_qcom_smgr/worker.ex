defmodule ExQcomSmgr.Worker do
  @moduledoc """
  Per-sensor worker: caches the latest sample and supervises its reader.

  Two processes per sensor:

    1. **The worker GenServer** (registered as `ExQcomSmgr.Worker.<type>`)
       holds the last sample seen and answers `read/1` from that cache.
       It never touches the IIO chardev, so `read/1` returns immediately.
    2. **The reader process** (registered as
       `ExQcomSmgr.Worker.<type>.reader`) is started with `spawn_monitor/1`
       — monitored, not linked. It configures the IIO buffer, opens
       `/dev/iio:deviceN`, loops on a blocking read, and sends each parsed
       sample to the worker.

  When the reader exits for any reason (device missing, open failure,
  EOF, read error), the worker gets a `:DOWN` message, logs it, writes
  `0` to the device's `buffer/enable`, and starts a new reader after an
  exponential backoff (`:retry_min_ms` doubling up to `:retry_max_ms`,
  reset whenever a sample arrives). The same backoff applies while the
  IIO device hasn't appeared yet. The worker itself does not crash, so a
  missing or broken sensor can't restart-storm the application.

  ## Blocking reads

  The chardev is opened as a raw file, so each blocking read occupies an
  Erlang dirty I/O scheduler thread until data arrives. Proximity may
  not report anything for a long time, so its reader can hold one such
  thread indefinitely. To keep this bounded there is at most one reader
  per sensor (enforced by the registered name): if a worker restarts
  while its old reader is still blocked, the new worker adopts that
  reader instead of starting a second one, and the reader delivers its
  samples to whichever worker is currently registered. A blocked reader
  can't be interrupted from Erlang; if no worker is registered when a
  read completes, the reader exits and closes the device.
  """
  use GenServer
  require Logger

  @doc false
  def name(type), do: :"#{__MODULE__}.#{type}"

  @doc false
  def reader_name(type), do: :"#{__MODULE__}.#{type}.reader"

  @doc "Starts the worker for `type` (one of `ExQcomSmgr.types/0`)."
  @spec start_link(ExQcomSmgr.sensor_type()) :: GenServer.on_start()
  def start_link(type) do
    GenServer.start_link(__MODULE__, type, name: name(type))
  end

  @doc """
  Returns the most recent sample for `type` without blocking on the
  device. See `ExQcomSmgr.read/1` for the return values.
  """
  @spec read(ExQcomSmgr.sensor_type()) :: {:ok, ExQcomSmgr.reading()} | {:error, term()}
  def read(type) do
    GenServer.call(name(type), :read, 1_000)
  catch
    :exit, {:timeout, _} -> {:error, :timeout}
    :exit, _ -> {:error, :not_running}
  end

  @impl GenServer
  def init(type) do
    state = %{type: type, latest: nil, reader: nil, ref: nil, sysfs: nil, failures: 0}
    {:ok, state, {:continue, :start_reader}}
  end

  @impl GenServer
  def handle_continue(:start_reader, state), do: {:noreply, start_reader(state)}

  @impl GenServer
  def handle_info(:retry, %{reader: nil} = state), do: {:noreply, start_reader(state)}
  def handle_info(:retry, state), do: {:noreply, state}

  def handle_info({:sample, sample}, state) do
    {:noreply, %{state | latest: sample, failures: 0}}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{ref: ref} = state) do
    Logger.warning("ex_qcom_smgr: #{state.type} reader exited: #{inspect(reason)}")

    # Don't touch the buffer if another reader already owns it.
    if reason != :reader_already_running, do: disable_buffer(state.sysfs)
    {:noreply, schedule_retry(%{state | reader: nil, ref: nil})}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl GenServer
  def handle_call(:read, _from, %{latest: nil} = state), do: {:reply, {:error, :no_data}, state}
  def handle_call(:read, _from, state), do: {:reply, {:ok, state.latest}, state}

  defp start_reader(%{type: type} = state) do
    sysfs =
      case ExQcomSmgr.device_path(type) do
        {:ok, path} -> path
        :error -> nil
      end

    case {Process.whereis(reader_name(type)), sysfs} do
      {pid, _} when is_pid(pid) ->
        Logger.info("ex_qcom_smgr: adopting existing #{type} reader")
        %{state | reader: pid, ref: Process.monitor(pid), sysfs: sysfs}

      {nil, nil} ->
        if state.failures == 0 do
          Logger.info("ex_qcom_smgr: #{type} IIO device not present yet, will retry")
        end

        schedule_retry(state)

      {nil, sysfs} ->
        {pid, ref} = spawn_monitor(fn -> reader_init(type, sysfs) end)
        Logger.info("ex_qcom_smgr: #{type} reader started on #{sysfs}")
        %{state | reader: pid, ref: ref, sysfs: sysfs}
    end
  end

  defp schedule_retry(state) do
    Process.send_after(self(), :retry, backoff(state.failures))
    %{state | failures: state.failures + 1}
  end

  @doc false
  @spec backoff(non_neg_integer()) :: pos_integer()
  def backoff(failures) do
    min_ms = Application.get_env(:ex_qcom_smgr, :retry_min_ms, 1_000)
    max_ms = Application.get_env(:ex_qcom_smgr, :retry_max_ms, 30_000)
    min(max_ms, min_ms * Integer.pow(2, min(failures, 16)))
  end

  # ---- reader process (owns the fd; blocking read loop) ----

  defp reader_init(type, sysfs) do
    try do
      Process.register(self(), reader_name(type))
    rescue
      ArgumentError -> exit(:reader_already_running)
    end

    spec = ExQcomSmgr.spec(type)

    with :ok <- enable_buffer(sysfs, type),
         {:ok, fd} <- :file.open(ExQcomSmgr.chardev_path(sysfs), [:read, :raw, :binary]) do
      scale = ExQcomSmgr.read_scale(sysfs, type)

      try do
        reader_loop(type, fd, spec, scale)
      after
        :file.close(fd)
      end
    else
      err -> exit({:open_failed, err})
    end
  end

  defp reader_loop(type, fd, spec, scale) do
    case :file.read(fd, spec.frame_size) do
      {:ok, data} when byte_size(data) == spec.frame_size ->
        deliver(type, {:sample, ExQcomSmgr.parse_sample(data, spec, scale)})
        reader_loop(type, fd, spec, scale)

      {:ok, _short} ->
        # Frame-size mismatch: back off briefly and keep reading.
        Process.sleep(50)
        reader_loop(type, fd, spec, scale)

      :eof ->
        exit(:eof)

      {:error, reason} ->
        exit({:read_error, reason})
    end
  end

  defp deliver(type, msg) do
    case Process.whereis(name(type)) do
      nil -> exit(:worker_gone)
      pid -> send(pid, msg)
    end
  end

  # ---- IIO buffer helpers ----

  defp enable_buffer(sysfs, type) do
    # Scan elements and length can only be changed while the buffer is off.
    disable_buffer(sysfs)

    Enum.each(ExQcomSmgr.scan_channels(type), fn chan ->
      _ = File.write(Path.join(sysfs, "scan_elements/#{chan}_en"), "1")
    end)

    _ = File.write(Path.join(sysfs, "buffer/length"), "16")
    _ = File.write(Path.join(sysfs, "buffer/enable"), "1")

    case File.read(Path.join(sysfs, "buffer/enable")) do
      {:ok, content} ->
        if String.trim(content) == "1",
          do: :ok,
          else: {:error, {:buffer_enable_failed, content}}

      other ->
        {:error, {:buffer_enable_failed, other}}
    end
  end

  defp disable_buffer(nil), do: :ok

  defp disable_buffer(sysfs) do
    _ = File.write(Path.join(sysfs, "buffer/enable"), "0")
    :ok
  end
end

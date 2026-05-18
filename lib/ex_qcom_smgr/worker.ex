defmodule ExQcomSmgr.Worker do
  @moduledoc """
  Per-sensor state holder.

  Two linked processes per sensor:

    1. **The Worker GenServer** owns the cache (last sample seen) and
       answers `read/1` by handing back what's in cache — never blocks
       on the IIO chardev.
    2. **The reader process** (spawn_link'd by the Worker) owns the
       `/dev/iio:deviceN` fd. It loops on `:file.read/2`, parses each
       sample, and sends it to the Worker via a message.

  Splitting the fd owner from the cache holder means the chardev can
  block forever (as it does for the prox sensor when no state-change
  events arrive) without affecting `read/1` latency or stalling other
  callers.

  If the reader process dies, the Worker's `:DOWN` handler logs it and
  starts a new reader after a short backoff. The Worker survives.
  """
  use GenServer
  require Logger

  def name(type), do: :"#{__MODULE__}.#{type}"

  def start_link(type) do
    GenServer.start_link(__MODULE__, type, name: name(type))
  end

  @doc """
  Returns the most recent sample. Non-blocking — completes in
  microseconds. Returns `{:error, :no_data}` if no sample has been
  received yet (typical right after boot, or for prox before the
  first state-change event).
  """
  def read(type), do: GenServer.call(name(type), :read, 1_000)

  @impl true
  def init(type) do
    state = %{type: type, latest: nil, reader_ref: nil}
    {:ok, state, {:continue, :start_reader}}
  end

  @impl true
  def handle_continue(:start_reader, state) do
    case ExQcomSmgr.device_path(state.type) do
      {:ok, sysfs} ->
        pid = start_reader(self(), sysfs, state.type)
        Logger.info("ex_qcom_smgr: reader for #{state.type} started")
        {:noreply, %{state | reader_ref: Process.monitor(pid)}}

      :error ->
        # ADSP / qcom-smgr not up yet — retry shortly.
        Process.send_after(self(), :retry, 1_000)
        {:noreply, state}
    end
  end

  @impl true
  def handle_info(:retry, state), do: handle_continue(:start_reader, state)

  def handle_info({:sample, sample}, state) do
    {:noreply, %{state | latest: sample}}
  end

  def handle_info({:DOWN, ref, :process, _, reason}, %{reader_ref: ref} = state) do
    Logger.warning("ex_qcom_smgr: reader #{state.type} died: #{inspect(reason)}")
    Process.send_after(self(), :retry, 1_000)
    {:noreply, %{state | reader_ref: nil}}
  end

  def handle_info(_, state), do: {:noreply, state}

  @impl true
  def handle_call(:read, _from, %{latest: nil} = state) do
    {:reply, {:error, :no_data}, state}
  end

  def handle_call(:read, _from, state) do
    {:reply, {:ok, state.latest}, state}
  end

  # ---- reader process (owns the fd; runs :file.read in a loop) ----

  defp start_reader(parent, sysfs, type) do
    spawn_link(fn -> reader_init(parent, sysfs, type) end)
  end

  defp reader_init(parent, sysfs, type) do
    with :ok <- enable_buffer(sysfs, type),
         {:ok, scale} <- read_scale(sysfs, type),
         {:ok, fd} <- open_chardev(sysfs) do
      spec = ExQcomSmgr.spec(type)

      try do
        reader_loop(parent, fd, spec, scale)
      after
        :file.close(fd)
      end
    else
      err ->
        Logger.warning("ex_qcom_smgr: reader #{type} init failed: #{inspect(err)}")
        exit({:open_failed, err})
    end
  end

  defp reader_loop(parent, fd, spec, scale) do
    case :file.read(fd, spec.frame_size) do
      {:ok, data} when byte_size(data) == spec.frame_size ->
        sample = ExQcomSmgr.parse_sample(data, spec, scale)
        send(parent, {:sample, sample})
        reader_loop(parent, fd, spec, scale)

      :eof ->
        # Buffer closed under us — Worker's :DOWN handler will restart.
        exit(:eof)

      {:error, reason} ->
        Logger.warning("ex_qcom_smgr: reader read error: #{inspect(reason)}")
        exit({:read_error, reason})

      {:ok, _short} ->
        # Frame-size mismatch — backoff briefly, the kernel may
        # have re-enabled with a different scan-elements set.
        Process.sleep(50)
        reader_loop(parent, fd, spec, scale)
    end
  end

  # ---- IIO setup helpers ----

  defp enable_buffer(sysfs, type) do
    Enum.each(ExQcomSmgr.scan_channels(type), fn chan ->
      _ = File.write(Path.join(sysfs, "scan_elements/#{chan}_en"), "1")
    end)

    _ = File.write(Path.join(sysfs, "buffer/length"), "16")
    _ = File.write(Path.join(sysfs, "buffer/enable"), "1")

    case File.read(Path.join(sysfs, "buffer/enable")) do
      {:ok, "1\n"} -> :ok
      other -> {:error, {:buffer_enable_failed, other}}
    end
  end

  defp read_scale(sysfs, type) do
    case File.read(Path.join(sysfs, ExQcomSmgr.scale_attr(type))) do
      {:ok, content} ->
        case Float.parse(String.trim(content)) do
          {f, _} -> {:ok, f}
          :error -> {:ok, 1.0}
        end

      _ ->
        {:ok, 1.0}
    end
  end

  defp open_chardev(sysfs) do
    index = sysfs |> Path.basename() |> String.replace_prefix("iio:device", "")
    File.open(Path.join("/dev", "iio:device" <> index), [:read, :raw, :binary])
  end
end

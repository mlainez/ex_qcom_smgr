defmodule ExQcomSmgr do
  @moduledoc """
  Read Fairphone 3+ IIO sensors (accelerometer, gyroscope, magnetometer,
  proximity) from Elixir.

  These are ADSP-bridged sensors exposed by the in-kernel `qcom_smgr`
  driver as **buffer-only** IIO devices: there are no `in_*_raw` sysfs
  files, so samples have to be read from the `/dev/iio:deviceN`
  character device after enabling the scan channels and the buffer.

  ## Design

  For each sensor type the application runs one `ExQcomSmgr.Worker`
  GenServer. The worker discovers the matching IIO device, then spawns
  and monitors a separate reader process that owns the chardev and loops
  on a blocking read, sending every parsed sample back to the worker.
  The worker only caches the most recent sample, so `read/1` never
  touches the device: it returns the cached sample immediately, or
  `{:error, :no_data}` if nothing has arrived yet. Samples are cached
  as they arrive, so the value you get may be old if the sensor has gone
  quiet (proximity, for example, only reports on state changes).

  If the IIO device isn't there yet (the ADSP is still booting) or the
  reader exits for any reason, the worker logs it and retries with
  exponential backoff. The worker itself does not crash, so a missing
  sensor never takes the application down.

  ## Units

  Values are the raw sample multiplied by the device's `in_*_scale`
  attribute (or `1.0` if that attribute is missing or unparsable), so
  they follow the IIO sysfs ABI units:

  | type     | keys            | unit                   |
  |----------|-----------------|------------------------|
  | `:accel` | `:x, :y, :z`    | `"m/s^2"`              |
  | `:gyro`  | `:x, :y, :z`    | `"rad/s"`              |
  | `:mag`   | `:x, :y, :z`    | `"G"` (Gauss)          |
  | `:prox`  | `:distance`     | `""` (unitless)        |

  The pressure sensor that `qcom_smgr` may also expose is not supported.

  ## Configuration

  All keys are optional; the defaults match a Nerves target.

      config :ex_qcom_smgr,
        sysfs_root: "/sys/bus/iio/devices",  # where IIO devices are listed
        dev_root: "/dev",                    # where iio:deviceN chardevs live
        retry_min_ms: 1_000,                 # first retry delay
        retry_max_ms: 30_000                 # backoff cap

  ## Example

      iex> ExQcomSmgr.read(:accel)
      {:ok, %{x: 0.07, y: -0.12, z: 9.81, unit: "m/s^2"}}

      iex> ExQcomSmgr.read(:prox)
      {:error, :no_data}
  """

  # qcom-smgr sample layout, confirmed from in_*_type on a running FP3+:
  #
  #   accel/gyro/mag: 3x s32 le, no timestamp        => 12 bytes
  #   prox:           1x u32 le, no timestamp        =>  4 bytes

  @sensors %{
    accel: %{
      iio_name: "qcom-smgr-accel",
      axes: [:x, :y, :z],
      scan_channels: ~w(in_accel_x in_accel_y in_accel_z),
      scale_attr: "in_accel_scale",
      frame_size: 12,
      unit: "m/s^2"
    },
    gyro: %{
      iio_name: "qcom-smgr-gyro",
      axes: [:x, :y, :z],
      scan_channels: ~w(in_anglvel_x in_anglvel_y in_anglvel_z),
      scale_attr: "in_anglvel_scale",
      frame_size: 12,
      unit: "rad/s"
    },
    mag: %{
      iio_name: "qcom-smgr-mag",
      axes: [:x, :y, :z],
      scan_channels: ~w(in_magn_x in_magn_y in_magn_z),
      scale_attr: "in_magn_scale",
      frame_size: 12,
      # IIO ABI: in_magn_* after scale is in Gauss.
      unit: "G"
    },
    prox: %{
      iio_name: "qcom-smgr-prox",
      axes: [:distance],
      scan_channels: ~w(in_proximity),
      scale_attr: "in_proximity_scale",
      frame_size: 4,
      unit: ""
    }
  }

  @type sensor_type :: :accel | :gyro | :mag | :prox
  @type reading :: %{required(atom()) => number() | String.t()}

  @doc "Returns the list of supported sensor types."
  @spec types() :: [sensor_type()]
  def types, do: Map.keys(@sensors)

  @doc "Returns the scan element names for `type`."
  @spec scan_channels(sensor_type()) :: [String.t()]
  def scan_channels(type), do: @sensors[type].scan_channels

  @doc "Returns the scale attribute filename for `type`."
  @spec scale_attr(sensor_type()) :: String.t()
  def scale_attr(type), do: @sensors[type].scale_attr

  @doc "Returns the full spec for `type` (iio_name, axes, frame_size, unit, ...)."
  @spec spec(sensor_type()) :: map()
  def spec(type), do: @sensors[type]

  @doc """
  Returns the most recent cached sample for `type`.

  Never blocks on the device. Returns:

    * `{:ok, reading}` — the last sample received, e.g.
      `%{x: 0.07, y: -0.12, z: 9.81, unit: "m/s^2"}`
    * `{:error, :no_data}` — no sample received yet (device not present,
      ADSP still booting, or a quiescent sensor such as proximity)
    * `{:error, :not_running}` — the `:ex_qcom_smgr` application (or this
      sensor's worker) isn't running
    * `{:error, :timeout}` — the worker didn't answer within 1 s

  Raises `FunctionClauseError` for an unknown `type`.
  """
  @spec read(sensor_type()) :: {:ok, reading()} | {:error, term()}
  def read(type) when is_map_key(@sensors, type), do: ExQcomSmgr.Worker.read(type)

  @doc "Calls `read/1` for every supported sensor type."
  @spec read_all() :: %{sensor_type() => {:ok, reading()} | {:error, term()}}
  def read_all do
    Map.new(types(), fn t -> {t, read(t)} end)
  end

  @doc """
  Returns a map of `type => sysfs path` for every `qcom-smgr-*` IIO
  device found under `root` (defaults to the `:sysfs_root` setting,
  `/sys/bus/iio/devices`). Returns `%{}` if `root` doesn't exist.
  """
  @spec discover(Path.t()) :: %{sensor_type() => String.t()}
  def discover(root \\ sysfs_root()) do
    case File.ls(root) do
      {:ok, entries} ->
        entries
        |> Enum.sort()
        |> Enum.reduce(%{}, fn entry, acc ->
          path = Path.join(root, entry)

          with {:ok, content} <- File.read(Path.join(path, "name")),
               {type, _} <- find_by_iio_name(String.trim(content)) do
            Map.put_new(acc, type, path)
          else
            _ -> acc
          end
        end)

      {:error, _} ->
        %{}
    end
  end

  defp find_by_iio_name(name) do
    Enum.find(@sensors, fn {_, spec} -> spec.iio_name == name end)
  end

  @doc false
  @spec device_path(sensor_type()) :: {:ok, String.t()} | :error
  def device_path(type), do: Map.fetch(discover(), type)

  @doc false
  def sysfs_root, do: Application.get_env(:ex_qcom_smgr, :sysfs_root, "/sys/bus/iio/devices")

  @doc false
  def dev_root, do: Application.get_env(:ex_qcom_smgr, :dev_root, "/dev")

  @doc false
  # Path of the chardev matching a sysfs device dir (".../iio:device3").
  @spec chardev_path(Path.t()) :: Path.t()
  def chardev_path(sysfs) do
    Path.join(dev_root(), Path.basename(sysfs))
  end

  @doc false
  # Reads and parses `in_*_scale`. Falls back to 1.0 when missing or
  # unparsable so the raw value is still usable.
  @spec read_scale(Path.t(), sensor_type()) :: float()
  def read_scale(sysfs, type) do
    case File.read(Path.join(sysfs, scale_attr(type))) do
      {:ok, content} -> parse_scale(content)
      {:error, _} -> 1.0
    end
  end

  @doc false
  @spec parse_scale(String.t()) :: float()
  def parse_scale(content) do
    case Float.parse(String.trim(content)) do
      {f, _} -> f
      :error -> 1.0
    end
  end

  @doc false
  # 3-axis sensors (accel/gyro/mag): 3x s32 le
  def parse_sample(
        <<a::little-signed-32, b::little-signed-32, c::little-signed-32>>,
        %{axes: [x, y, z]} = spec,
        scale
      ) do
    %{x => a * scale, y => b * scale, z => c * scale, unit: spec.unit}
  end

  # Proximity: 1x u32 le
  def parse_sample(<<v::little-unsigned-32>>, %{axes: [single]} = spec, scale) do
    %{single => v * scale, unit: spec.unit}
  end
end

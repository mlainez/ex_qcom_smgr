defmodule ExQcomSmgr do
  @moduledoc """
  Read FP3+ IIO sensors (accel, gyro, mag, prox) from Elixir.

  These are ADSP-bridged sensors exposed by the in-kernel `qcom_smgr`
  driver as buffer-only IIO devices — there are no `in_*_raw` sysfs
  files. One `ExQcomSmgr.Worker` GenServer per sensor opens
  `/dev/iio:deviceN` once and serves `read/1` synchronously from
  `handle_call`. Per-sensor isolation keeps a quiescent prox from
  blocking accel/gyro/mag reads.

  ## Example

      iex> ExQcomSmgr.read(:accel)
      {:ok, %{x: 0.07, y: -0.12, z: 9.81, unit: "m/s^2"}}

      iex> ExQcomSmgr.read_all()
      %{
        accel: {:ok, %{...}},
        gyro:  {:ok, %{...}},
        mag:   {:ok, %{...}},
        prox:  {:ok, %{distance: 0, unit: ""}}
      }
  """

  @iio_sysfs "/sys/bus/iio/devices"

  # qcom-smgr sample layout, confirmed from in_*_type on a running FP3+:
  #
  #   accel/gyro/mag: 3× s32 le, no timestamp        => 12 bytes
  #   prox:           1× u32 le, no timestamp        =>  4 bytes

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
      unit: "T"
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
  @type reading :: %{required(atom()) => number(), unit: String.t()}

  @doc "Returns the list of supported sensor types."
  @spec types() :: [sensor_type()]
  def types, do: Map.keys(@sensors)

  @doc "Returns the scan element names for `type`."
  @spec scan_channels(sensor_type()) :: [String.t()]
  def scan_channels(type), do: @sensors[type].scan_channels

  @doc "Returns the scale-attr filename for `type`."
  @spec scale_attr(sensor_type()) :: String.t()
  def scale_attr(type), do: @sensors[type].scale_attr

  @doc "Returns the full spec for `type` (axes, frame_size, unit, …)."
  def spec(type), do: @sensors[type]

  @doc """
  Reads one sample from `type` via `ExQcomSmgr.Reader`.

  Returns `{:ok, reading}`; on failure `{:error, reason}` (most common:
  `:no_data` when the buffer is empty, `:not_open` if the fd wasn't
  set up at boot — typically means the IIO device wasn't present yet).
  """
  @spec read(sensor_type()) :: {:ok, reading()} | {:error, term()}
  def read(type) when is_map_key(@sensors, type), do: ExQcomSmgr.Worker.read(type)

  @doc "Reads all four sensors."
  @spec read_all() :: %{sensor_type() => {:ok, reading()} | {:error, term()}}
  def read_all do
    Map.new(types(), fn t -> {t, read(t)} end)
  end

  @doc """
  Returns a map of `type => sysfs path` for every qcom-smgr-* IIO
  device the kernel currently exposes.
  """
  @spec discover() :: %{sensor_type() => String.t()}
  def discover do
    case File.ls(@iio_sysfs) do
      {:ok, entries} ->
        Enum.reduce(entries, %{}, fn entry, acc ->
          path = Path.join(@iio_sysfs, entry)
          name = path |> Path.join("name") |> File.read() |> case do
            {:ok, content} -> String.trim(content)
            _ -> nil
          end

          case Enum.find(@sensors, fn {_, spec} -> spec.iio_name == name end) do
            {type, _} -> Map.put(acc, type, path)
            nil -> acc
          end
        end)

      _ ->
        %{}
    end
  end

  @doc false
  def device_path(type) do
    case Map.fetch(discover(), type) do
      {:ok, path} -> {:ok, path}
      :error -> :error
    end
  end

  # ---- shared helpers used by Reader ----

  @doc false
  # 3-axis sensors (accel/gyro/mag): 3× s32 le
  def parse_sample(<<a::little-signed-32, b::little-signed-32, c::little-signed-32>>,
                   %{axes: [x, y, z]} = spec, scale) do
    %{
      x => a * scale,
      y => b * scale,
      z => c * scale,
      unit: spec.unit
    }
  end

  # Proximity: 1× u32 le
  def parse_sample(<<v::little-unsigned-32>>, %{axes: [single]} = spec, scale) do
    %{
      single => v * scale,
      unit: spec.unit
    }
  end
end

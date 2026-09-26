# ex_qcom_smgr

> ### ⚠️ Very early work — built for a workshop, not for production
>
> Written for the **Goatmire Elixir workshop** on running Nerves on Fairphone 3 hardware. There are no stability guarantees and APIs will change without notice.

Read Fairphone 3+ IIO sensors (accelerometer, gyroscope, magnetometer,
proximity) from Elixir on Nerves.

## Install

```elixir
defp deps do
  [{:ex_qcom_smgr, github: "mlainez/ex_qcom_smgr"}]
end
```

This pulls in [`ex_remoteproc`](https://github.com/mlainez/ex_remoteproc).
It is an ordering-only dependency: these sensors are bridged through the
ADSP, so the DSP has to be running before the IIO devices appear, and
listing it makes OTP start `ex_remoteproc` first.

## Usage

```elixir
ExQcomSmgr.read(:accel)
#=> {:ok, %{x: 0.07, y: -0.12, z: 9.81, unit: "m/s^2"}}

ExQcomSmgr.read(:prox)
#=> {:error, :no_data}   # nothing reported yet

ExQcomSmgr.read_all()
#=> %{accel: {:ok, %{...}}, gyro: {:ok, %{...}},
#     mag: {:ok, %{...}}, prox: {:error, :no_data}}

ExQcomSmgr.types()
#=> [:accel, :gyro, :mag, :prox]
```

`read/1` returns the **most recent cached sample** and never blocks on the
device. Possible results:

| result                    | meaning                                                  |
|---------------------------|----------------------------------------------------------|
| `{:ok, reading}`          | last sample received                                     |
| `{:error, :no_data}`      | no sample yet (device missing, ADSP booting, quiet sensor) |
| `{:error, :not_running}`  | the application / that sensor's worker isn't running     |
| `{:error, :timeout}`      | the worker didn't answer within 1 s                      |

Readings are raw values multiplied by the device's `in_*_scale` attribute
(`1.0` if it's missing), in IIO ABI units:

| type     | keys         | unit              |
|----------|--------------|-------------------|
| `:accel` | `x`, `y`, `z`| `"m/s^2"`         |
| `:gyro`  | `x`, `y`, `z`| `"rad/s"`         |
| `:mag`   | `x`, `y`, `z`| `"G"` (Gauss)     |
| `:prox`  | `distance`   | `""` (unitless)   |

The pressure sensor that `qcom_smgr` may also expose is **not supported**.

## Configuration

All optional; defaults are right for a Nerves target.

```elixir
config :ex_qcom_smgr,
  sysfs_root: "/sys/bus/iio/devices",
  dev_root: "/dev",
  retry_min_ms: 1_000,   # first retry delay
  retry_max_ms: 30_000   # backoff cap
```

## How it works

The in-kernel `qcom_smgr` driver exposes these sensors as **buffer-only
IIO devices**. There are no `in_*_raw` sysfs files to `cat`, so you have
to enable the scan channels and the buffer, open `/dev/iio:deviceN`, and
read buffered samples.

Per sensor, the application runs an `ExQcomSmgr.Worker` GenServer that
caches the latest sample, plus a monitored (not linked) reader process
that owns the chardev and loops on a blocking read. When the device is
missing or the reader exits (open failure, EOF, read error), the worker
logs it, disables the IIO buffer, and retries with exponential backoff.
The worker doesn't crash, so a missing sensor can't take the application
(and, with `start_permanent`, the device) down.

Each blocking read occupies one Erlang dirty I/O scheduler thread until
data arrives, and proximity can stay quiet for a long time. There's at
most one reader per sensor (four threads at most); a restarted worker
adopts a still-blocked reader rather than starting another.

## Toolchain

Built and tested with Erlang/OTP 29.1.1 and Elixir 1.20.4, matching the
official Nerves systems (see `.tool-versions`).

`mix test` runs on the host against a fake sysfs/dev tree and doesn't
start the application. The reader/retry rewrite has **not** been
re-verified on a Fairphone 3+ yet.

## License

Apache-2.0

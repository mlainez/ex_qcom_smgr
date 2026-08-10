# ex_qcom_smgr

> ### ⚠️ Very early work — built for a workshop, not for production
>
> Written for the **Goatmire Elixir workshop** on running Nerves on
> Fairphone 3 hardware. It exists for tinkering and teaching.
>
> **Not an actively maintained project** (yet) — no stability
> guarantees, no test coverage, APIs will change without notice.

Read Fairphone 3+ IIO sensors — accelerometer, gyroscope, magnetometer,
proximity — from Elixir.

## Install

```elixir
defp deps do
  [{:ex_qcom_smgr, github: "mlainez/ex_qcom_smgr"}]
end
```

Pulls in [`ex_remoteproc`](https://github.com/mlainez/ex_remoteproc):
these sensors are ADSP-bridged, so the DSP has to be running first.

## Usage

```elixir
ExQcomSmgr.read(:accel)
#=> {:ok, %{x: 0.07, y: -0.12, z: 9.81, unit: "m/s^2"}}

ExQcomSmgr.read_all()
#=> %{accel: {:ok, %{…}}, gyro: {:ok, %{…}},
#     mag: {:ok, %{…}}, prox: {:ok, %{…}}}

ExQcomSmgr.types()
#=> [:accel, :gyro, :mag, :prox]
```

## Why this exists

These sensors come from the in-kernel `qcom_smgr` driver as
**buffer-only IIO devices**. There are no `in_*_raw` sysfs files to
`cat` — the usual quick path to an IIO sensor doesn't work here. You
have to open `/dev/iio:deviceN`, configure scan channels, and read
buffered samples.

This library does that once per sensor, in a `GenServer` that serves
`read/1` synchronously. One process per sensor is deliberate: proximity
is quiescent most of the time, and sharing a process would let it block
accelerometer and gyro reads behind it.

## License

Apache-2.0

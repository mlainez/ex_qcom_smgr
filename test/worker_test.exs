defmodule ExQcomSmgr.WorkerTest do
  use ExUnit.Case, async: false

  alias ExQcomSmgr.Worker

  @moduletag :tmp_dir
  @moduletag capture_log: true

  setup %{tmp_dir: tmp_dir} do
    sysfs = Path.join(tmp_dir, "sys")
    dev = Path.join(tmp_dir, "dev")
    File.mkdir_p!(sysfs)
    File.mkdir_p!(dev)

    for {k, v} <- [sysfs_root: sysfs, dev_root: dev, retry_min_ms: 10, retry_max_ms: 40] do
      Application.put_env(:ex_qcom_smgr, k, v)
    end

    on_exit(fn ->
      for k <- [:sysfs_root, :dev_root, :retry_min_ms, :retry_max_ms] do
        Application.delete_env(:ex_qcom_smgr, k)
      end
    end)

    %{sysfs: sysfs, dev: dev}
  end

  defp add_accel(sysfs) do
    dir = Path.join(sysfs, "iio:device0")
    File.mkdir_p!(Path.join(dir, "scan_elements"))
    File.mkdir_p!(Path.join(dir, "buffer"))
    File.write!(Path.join(dir, "name"), "qcom-smgr-accel\n")
    File.write!(Path.join(dir, "in_accel_scale"), "0.5\n")
    dir
  end

  defp frame(x, y, z), do: <<x::little-signed-32, y::little-signed-32, z::little-signed-32>>

  defp eventually(fun, tries \\ 100) do
    case fun.() do
      falsy when falsy in [nil, false] and tries > 0 ->
        Process.sleep(10)
        eventually(fun, tries - 1)

      result ->
        result
    end
  end

  test "backoff/1 doubles up to the cap" do
    assert Enum.map(0..4, &Worker.backoff/1) == [10, 20, 40, 40, 40]
  end

  test "worker stays up and retries while the device is missing" do
    pid = start_supervised!({Worker, :accel})
    Process.sleep(100)
    assert Process.alive?(pid)
    assert Worker.read(:accel) == {:error, :no_data}
    assert Process.whereis(Worker.reader_name(:accel)) == nil
  end

  test "reader open failures don't kill the worker; it recovers once the chardev appears",
       %{sysfs: sysfs, dev: dev} do
    dir = add_accel(sysfs)
    pid = start_supervised!({Worker, :accel})

    # No chardev yet: the reader exits with {:open_failed, _} repeatedly.
    Process.sleep(100)
    assert Process.alive?(pid)
    assert Worker.read(:accel) == {:error, :no_data}

    File.write!(Path.join(dev, "iio:device0"), frame(2, 4, -6))

    assert {:ok, sample} = eventually(fn -> match?({:ok, _}, r = Worker.read(:accel)) && r end)
    assert sample == %{x: 1.0, y: 2.0, z: -3.0, unit: "m/s^2"}
    assert Process.alive?(pid)

    # The buffer was configured before reading.
    assert File.read!(Path.join(dir, "scan_elements/in_accel_x_en")) == "1"
    assert File.read!(Path.join(dir, "buffer/length")) == "16"
  end

  test "reader EOF keeps the cached sample and disables the buffer", %{sysfs: sysfs, dev: dev} do
    Application.put_env(:ex_qcom_smgr, :retry_min_ms, 60_000)
    Application.put_env(:ex_qcom_smgr, :retry_max_ms, 60_000)

    dir = add_accel(sysfs)
    File.write!(Path.join(dev, "iio:device0"), frame(2, 2, 2) <> frame(10, 20, 30))
    pid = start_supervised!({Worker, :accel})

    # The fake chardev is a regular file: after two frames the reader hits EOF.
    assert eventually(fn -> File.read(Path.join(dir, "buffer/enable")) == {:ok, "0"} end)
    assert Process.whereis(Worker.reader_name(:accel)) == nil
    assert Process.alive?(pid)
    assert Worker.read(:accel) == {:ok, %{x: 5.0, y: 10.0, z: 15.0, unit: "m/s^2"}}
  end
end

defmodule ExQcomSmgrTest do
  use ExUnit.Case, async: false

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    sysfs = Path.join(tmp_dir, "sys")
    dev = Path.join(tmp_dir, "dev")
    File.mkdir_p!(sysfs)
    File.mkdir_p!(dev)

    Application.put_env(:ex_qcom_smgr, :sysfs_root, sysfs)
    Application.put_env(:ex_qcom_smgr, :dev_root, dev)

    on_exit(fn ->
      Application.delete_env(:ex_qcom_smgr, :sysfs_root)
      Application.delete_env(:ex_qcom_smgr, :dev_root)
    end)

    %{sysfs: sysfs, dev: dev}
  end

  defp add_device(sysfs, index, name, files \\ %{}) do
    dir = Path.join(sysfs, "iio:device#{index}")
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "name"), name <> "\n")
    Enum.each(files, fn {f, c} -> File.write!(Path.join(dir, f), c) end)
    dir
  end

  describe "types/0 and spec/1" do
    test "lists the four supported sensors" do
      assert Enum.sort(ExQcomSmgr.types()) == [:accel, :gyro, :mag, :prox]
    end

    test "magnetometer is reported in Gauss" do
      assert ExQcomSmgr.spec(:mag).unit == "G"
    end
  end

  describe "parse_sample/3" do
    test "parses a 3-axis s32 little-endian frame and applies scale" do
      data = <<100::little-signed-32, -200::little-signed-32, 981::little-signed-32>>

      assert %{x: x, y: y, z: z, unit: "m/s^2"} =
               ExQcomSmgr.parse_sample(data, ExQcomSmgr.spec(:accel), 0.01)

      assert_in_delta x, 1.0, 1.0e-9
      assert_in_delta y, -2.0, 1.0e-9
      assert_in_delta z, 9.81, 1.0e-9
    end

    test "parses a proximity u32 frame" do
      data = <<0xFFFFFFFF::little-unsigned-32>>

      assert ExQcomSmgr.parse_sample(data, ExQcomSmgr.spec(:prox), 1.0) ==
               %{distance: 4_294_967_295.0, unit: ""}
    end

    test "rejects a frame of the wrong size" do
      assert_raise FunctionClauseError, fn ->
        ExQcomSmgr.parse_sample(<<1, 2, 3>>, ExQcomSmgr.spec(:gyro), 1.0)
      end
    end
  end

  describe "scale handling" do
    test "parse_scale/1 parses kernel formatted values" do
      assert ExQcomSmgr.parse_scale("0.000598550\n") == 0.00059855
      assert ExQcomSmgr.parse_scale("2\n") == 2.0
    end

    test "parse_scale/1 falls back to 1.0 on garbage" do
      assert ExQcomSmgr.parse_scale("n/a\n") == 1.0
      assert ExQcomSmgr.parse_scale("") == 1.0
    end

    test "read_scale/2 reads the attribute or falls back to 1.0", %{sysfs: sysfs} do
      dir = add_device(sysfs, 0, "qcom-smgr-gyro", %{"in_anglvel_scale" => "0.5\n"})
      assert ExQcomSmgr.read_scale(dir, :gyro) == 0.5
      assert ExQcomSmgr.read_scale(dir, :accel) == 1.0
    end
  end

  describe "discover/1" do
    test "returns %{} when the sysfs root doesn't exist", %{tmp_dir: tmp_dir} do
      assert ExQcomSmgr.discover(Path.join(tmp_dir, "missing")) == %{}
    end

    test "maps qcom-smgr devices by name and ignores others", %{sysfs: sysfs} do
      accel = add_device(sysfs, 0, "qcom-smgr-accel")
      _other = add_device(sysfs, 1, "some-adc")
      prox = add_device(sysfs, 2, "qcom-smgr-prox")
      File.mkdir_p!(Path.join(sysfs, "trigger0"))

      assert ExQcomSmgr.discover() == %{accel: accel, prox: prox}
      assert ExQcomSmgr.device_path(:accel) == {:ok, accel}
      assert ExQcomSmgr.device_path(:gyro) == :error
    end

    test "chardev_path/1 maps a sysfs dir to the configured dev root",
         %{sysfs: sysfs, dev: dev} do
      assert ExQcomSmgr.chardev_path(Path.join(sysfs, "iio:device7")) ==
               Path.join(dev, "iio:device7")
    end
  end

  test "read/1 returns an error when the app isn't running" do
    assert ExQcomSmgr.read(:accel) == {:error, :not_running}
  end
end

defmodule ExQcomSmgr.MixProject do
  use Mix.Project

  def project do
    [
      app: :ex_qcom_smgr,
      version: "0.1.0",
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases()
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {ExQcomSmgr.Application, []}
    ]
  end

  defp deps do
    [
      # Ordering-only dependency: no ExRemoteproc functions are called.
      # Listing it makes OTP start :ex_remoteproc (which boots the ADSP)
      # before this app; the qcom-smgr IIO devices only appear once the
      # ADSP is running.
      {:ex_remoteproc, github: "mlainez/ex_remoteproc"}
    ]
  end

  # Tests run on the host: don't start this app (or ex_remoteproc),
  # which would poke at /sys and /dev.
  defp aliases do
    [test: "test --no-start"]
  end
end

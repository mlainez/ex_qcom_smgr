defmodule ExQcomSmgr.MixProject do
  use Mix.Project

  def project do
    [
      app: :ex_qcom_smgr,
      version: "0.1.0",
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      deps: deps()
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
      # ADSP needs to be running before qcom-smgr IIO devices exist.
      {:ex_remoteproc, path: "../ex_remoteproc"}
    ]
  end
end

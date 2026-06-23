defmodule DockdRpc.MixProject do
  use Mix.Project

  def project do
    [
      app: :dockd_rpc,
      version: "0.1.0",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {Dockd.RPC.Application, []}
    ]
  end

  defp deps do
    [
      {:dockd, in_umbrella: true},
      {:libcluster, "~> 3.5"}
    ]
  end
end

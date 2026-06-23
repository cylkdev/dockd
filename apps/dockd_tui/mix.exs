defmodule DockdTui.MixProject do
  use Mix.Project

  def project do
    [
      app: :dockd_tui,
      version: "0.1.0",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      escript: escript()
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp deps do
    [
      {:dockd, in_umbrella: true},
      {:docker, github: "cylkdev/docker", branch: "main"},
      {:ex_ratatui, "~> 0.10.0"}
    ]
  end

  defp escript do
    [
      main_module: Dockd.Tui.CLI,
      name: "dockd_tui"
    ]
  end
end

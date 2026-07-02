defmodule DockdCli.MixProject do
  use Mix.Project

  def project do
    [
      app: :dockd_cli,
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
      extra_applications: [:logger]
    ] ++ mod()
  end

  # Only wire the Burrito Application entrypoint (`DockdCli.Main.start/2`,
  # which runs the CLI and halts the VM) for the `prod` release build.
  # Setting `:mod` unconditionally would make `mix test`/`mix dockd` (which
  # start the `:dockd_cli` OTP application as a normal dependency) run the
  # CLI and `System.halt/1` immediately, breaking the test suite and the
  # existing Mix task entrypoint. See apps/dockd_cli/lib/dockd_cli/main.ex
  # for the corresponding `start/2` guard note.
  defp mod do
    if Mix.env() == :prod, do: [mod: {DockdCli.Main, []}], else: []
  end

  defp deps do
    [
      {:dockd, in_umbrella: true},
      {:dockd_ssh, in_umbrella: true},
      {:optimus, "~> 0.5"},
      {:burrito, "~> 1.0"}
    ]
  end
end

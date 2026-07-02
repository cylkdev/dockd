defmodule DockdCli.CLI do
  @moduledoc "Optimus command specification and dispatch for the `dockd` binary."
  alias DockdCli.Commands

  @spec spec() :: Optimus.t()
  def spec do
    Optimus.new!(
      name: "dockd",
      description: "Manage local Docker workspaces",
      version: "0.1.0",
      allow_unknown_args: false,
      parse_double_dash: true,
      options: global_options(),
      subcommands: [
        instance: [
          name: "instance",
          about: "Manage instances",
          subcommands: [
            list: [name: "list", about: "List instances"],
            run: [
              name: "run",
              about: "Provision and start an instance",
              options: run_options(),
              flags: run_flags()
            ],
            stop: [
              name: "stop",
              about: "Stop an instance",
              args: [name: [required: false]],
              flags: [all: [long: "--all"]]
            ],
            start: [name: "start", about: "Start an instance", args: [name: [required: false]]],
            restart: [
              name: "restart",
              about: "Restart an instance",
              args: [name: [required: false]]
            ],
            destroy: [
              name: "destroy",
              about: "Destroy an instance",
              args: [name: [required: false]],
              flags: [all: [long: "--all"], force: [long: "--force"]]
            ],
            logs: [
              name: "logs",
              about: "Print instance logs",
              args: [name: [required: false]],
              options: log_options(),
              flags: log_flags()
            ],
            inspect: [
              name: "inspect",
              about: "Inspect an instance",
              args: [name: [required: false]]
            ]
          ]
        ],
        package: [
          name: "package",
          about: "Manage packages",
          subcommands: [
            install: [
              name: "install",
              about: "Install packages from a remote source",
              args: [type: [required: true]],
              options: package_install_options()
            ],
            show: [name: "show", about: "Show installed packages"],
            validate: [
              name: "validate",
              about: "Validate a package",
              args: [name: [required: false]]
            ]
          ]
        ],
        info: [name: "info", about: "Show aggregate dockd state"]
      ]
    )
  end

  # Global options are declared with `global: true` (there is no top-level
  # `global_options:` key in this Optimus version — see deps/optimus/lib/optimus/builder.ex,
  # `build_global_props/3` / `merge_globals_into_subcommand/2`). They get merged into
  # every subcommand's own `options` list, so they must be passed *after* the
  # subcommand name on the command line and land in that subcommand's `parsed.options`.
  defp global_options,
    do: [
      socket: [
        long: "--socket",
        help: "Docker socket path (overrides DOCKER_SOCKET)",
        required: false,
        global: true
      ],
      host: [
        long: "--host",
        help: "Docker host (overrides DOCKER_HOST)",
        required: false,
        global: true
      ]
    ]

  # Option/flag names MUST match the map keys the command modules read.
  defp run_options,
    do: [
      image: [long: "--image"],
      dockerfile: [long: "--dockerfile"],
      tag: [long: "--tag"],
      package: [long: "--package"],
      preset: [long: "--preset"],
      name: [long: "--name"]
    ]

  defp run_flags, do: [short: [long: "--short"], detached: [long: "--detached"]]

  defp log_options,
    do: [
      tail: [long: "--tail", parser: :integer],
      since: [long: "--since", parser: :integer],
      until: [long: "--until", parser: :integer]
    ]

  defp log_flags,
    do: [
      timestamps: [long: "--timestamps"],
      stdout_only: [long: "--stdout-only"],
      stderr_only: [long: "--stderr-only"]
    ]

  defp package_install_options, do: [source: [long: "--source"]]

  @spec dispatch({[atom()], Optimus.ParseResult.t()}) :: :ok | {:error, term()}
  def dispatch({path, parsed}) do
    if command = command_for(path) do
      flags = Map.take(Map.new(parsed.options || %{}), [:socket, :host])
      opts = DockdCli.Options.resolve(flags, System.get_env())
      args = build_args(parsed)
      apply(command, :run, [args, opts])
    else
      # Parent subcommand invoked with no leaf child (e.g. `dockd instance`
      # with no further subcommand). Optimus.parse/2 still returns an
      # `{:ok, path, parsed}` tuple for this case, but `path` doesn't
      # resolve to a runnable leaf command. Print help and exit cleanly
      # instead of crashing.
      IO.puts(Optimus.help(spec()))
      :ok
    end
  end

  defp build_args(parsed) do
    %{}
    |> Map.merge(Map.new(parsed.args || %{}))
    |> Map.merge(Map.new(parsed.options || %{}))
    |> Map.merge(Map.new(parsed.flags || %{}))
  end

  @spec command_for([atom()]) :: module() | nil
  defp command_for([:instance, :list]), do: Commands.Instance.List
  defp command_for([:instance, :run]), do: Commands.Instance.Run
  defp command_for([:instance, :stop]), do: Commands.Instance.Stop
  defp command_for([:instance, :start]), do: Commands.Instance.Start
  defp command_for([:instance, :restart]), do: Commands.Instance.Restart
  defp command_for([:instance, :destroy]), do: Commands.Instance.Destroy
  defp command_for([:instance, :logs]), do: Commands.Instance.Logs
  defp command_for([:instance, :inspect]), do: Commands.Instance.Inspect
  defp command_for([:package, :install]), do: Commands.Package.Install
  defp command_for([:package, :show]), do: Commands.Package.Show
  defp command_for([:package, :validate]), do: Commands.Package.Validate
  defp command_for([:info]), do: Commands.Info
  defp command_for(_incomplete_path), do: nil
end

defmodule DockdCLI.CLI do
  @moduledoc "Optimus command specification and dispatch for the `dockd` binary."
  alias DockdCLI.Commands
  alias DockdCLI.Output

  @spec spec() :: Optimus.t()
  def spec do
    Optimus.new!(
      name: "dockd",
      description: "Manage local Docker workspaces",
      version: "0.1.0",
      allow_unknown_args: false,
      parse_double_dash: true,
      options: global_options(),
      flags: global_flags(),
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
              options: [name: [long: "--name", help: "Instance name"]],
              flags: [all: [long: "--all"]]
            ],
            start: [
              name: "start",
              about: "Start an instance",
              options: [name: [long: "--name", help: "Instance name"]]
            ],
            restart: [
              name: "restart",
              about: "Restart an instance",
              options: [name: [long: "--name", help: "Instance name"]]
            ],
            destroy: [
              name: "destroy",
              about: "Destroy an instance",
              options: [name: [long: "--name", help: "Instance name"]],
              flags: [all: [long: "--all"], force: [long: "--force"]]
            ],
            logs: [
              name: "logs",
              about: "Print instance logs",
              options: [name: [long: "--name", help: "Instance name"]] ++ log_options(),
              flags: log_flags()
            ],
            inspect: [
              name: "inspect",
              about: "Inspect an instance",
              options: [name: [long: "--name", help: "Instance name"]]
            ],
            shell: [
              name: "shell",
              about: "Open a shell in an instance (opens a new terminal window)",
              options: [
                name: [long: "--name", help: "Instance name"],
                shell: [long: "--shell", help: "Override the program to run"]
              ],
              flags: [
                print: [
                  long: "--print",
                  help: "Print the docker exec command instead of opening a window"
                ]
              ]
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
              options:
                [type: [long: "--type", required: true, help: "Package type"]] ++
                  package_install_options()
            ],
            show: [name: "show", about: "Show installed packages"],
            validate: [
              name: "validate",
              about: "Validate a package",
              options: [name: [long: "--name", help: "Package name"]]
            ]
          ]
        ],
        info: [name: "info", about: "Show aggregate dockd state"],
        tui: [name: "tui", about: "Open the dockd dashboard (visual TUI)"],
        ssh: [
          name: "ssh",
          about: "SSH helpers",
          subcommands: [
            dial_stdio_script: [
              name: "dial_stdio_script",
              about: "Manage the docker dial-stdio bridge script",
              subcommands: [
                generate: [
                  name: "generate",
                  about: "Render the dial-stdio script to disk",
                  options: [output_dir: [long: "--output-dir"]],
                  flags: [force: [long: "--force"]]
                ],
                install: [
                  name: "install",
                  about: "Deploy the dial-stdio script to a remote host",
                  options: [
                    user_at_host: [long: "--target", required: true, help: "user@host"],
                    script_path: [long: "--script-path"],
                    remote_path: [long: "--remote-path"],
                    identity: [long: "--identity"],
                    port: [long: "--port"]
                  ]
                ]
              ]
            ]
          ]
        ]
      ]
    )
  end

  @spec run([String.t()]) :: :ok | {:error, term()}
  def run(argv) do
    ensure_started()
    spec = spec()

    case Optimus.parse(spec, argv) do
      {:ok, path, parsed} ->
        case dispatch({path, parsed}) do
          {:json, result} -> report_json(result)
          {:human, result} -> report(result)
        end

      {:ok, _parsed} ->
        IO.puts(Optimus.help(spec))
        :ok

      {:error, reasons} ->
        Enum.each(List.wrap(reasons), &Output.error/1)
        {:error, :usage}

      {:error, _path, reasons} ->
        Enum.each(List.wrap(reasons), &Output.error/1)
        {:error, :usage}

      :version ->
        IO.puts("#{spec.name} #{spec.version}")
        :ok

      :help ->
        IO.puts(Optimus.help(spec))
        :ok

      {:help, _subcommand_path} ->
        IO.puts(Optimus.help(spec))
        :ok
    end
  end

  defp report(:ok), do: :ok

  defp report({:error, %Dockd.Error{} = err}) do
    Output.error(Exception.message(err))
    {:error, err}
  end

  defp report({:error, msg}) when is_binary(msg) do
    Output.error(msg)
    {:error, msg}
  end

  defp report({:error, other}) do
    Output.error(inspect(other))
    {:error, other}
  end

  defp report_json(:ok), do: :ok

  defp report_json({:error, %Dockd.Error{} = err}) do
    Output.json_error(%{phase: err.phase, message: Exception.message(err)})
    {:error, err}
  end

  defp report_json({:error, msg}) when is_binary(msg) do
    Output.json_error(%{message: msg})
    {:error, msg}
  end

  defp report_json({:error, other}) do
    Output.json_error(%{message: inspect(other)})
    {:error, other}
  end

  defp ensure_started do
    {:ok, _} = Application.ensure_all_started(:dockd)
    :ok
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

  defp global_flags,
    do: [
      json: [
        long: "--json",
        help: "Emit machine-readable JSON (ignored by `logs`)",
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

  @spec dispatch({[atom()], Optimus.ParseResult.t()}) ::
          {:human | :json, :ok | {:error, term()}}
  def dispatch({path, parsed}) do
    json? = Map.get(Map.new(parsed.flags || %{}), :json, false)

    if command = command_for(path) do
      flags = Map.take(Map.new(parsed.options || %{}), [:socket, :host])
      opts = DockdCLI.Options.resolve(flags, System.get_env())
      args = build_args(parsed)

      json_capable? =
        json? and Code.ensure_loaded?(command) and function_exported?(command, :run_json, 2)

      fun = if json_capable?, do: :run_json, else: :run
      format = if json_capable?, do: :json, else: :human
      {format, apply(command, fun, [args, opts])}
    else
      # Parent subcommand invoked with no leaf child (e.g. `dockd instance`
      # with no further subcommand). Optimus.parse/2 still returns an
      # `{:ok, path, parsed}` tuple for this case, but `path` doesn't
      # resolve to a runnable leaf command. Print help and exit cleanly
      # instead of crashing.
      IO.puts(Optimus.help(spec()))
      {:human, :ok}
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
  defp command_for([:instance, :shell]), do: Commands.Instance.Shell
  defp command_for([:package, :install]), do: Commands.Package.Install
  defp command_for([:package, :show]), do: Commands.Package.Show
  defp command_for([:package, :validate]), do: Commands.Package.Validate
  defp command_for([:info]), do: Commands.Info
  defp command_for([:tui]), do: Commands.Tui

  defp command_for([:ssh, :dial_stdio_script, :generate]),
    do: Commands.Ssh.DialStdioScript.Generate

  defp command_for([:ssh, :dial_stdio_script, :install]),
    do: Commands.Ssh.DialStdioScript.Install

  defp command_for(_incomplete_path), do: nil
end

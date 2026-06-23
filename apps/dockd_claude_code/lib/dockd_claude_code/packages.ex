defmodule Dockd.ClaudeCode.Packages do
  @moduledoc """
  Generates plain dockd package definitions for Claude Code.

  Each package is written to `<packages_path>/<package_name>/` with a
  `package.json` and `Dockerfile`.
  """

  @dockerfile """
  FROM node:20-slim
  RUN npm install -g @anthropic-ai/claude-code
  """

  @env [
    %{"name" => "ANTHROPIC_API_KEY", "optional" => true},
    %{"name" => "CLAUDE_CODE_OAUTH_TOKEN", "optional" => true},
    %{"name" => "AWS_ACCESS_KEY_ID", "optional" => true},
    %{"name" => "AWS_SECRET_ACCESS_KEY", "optional" => true},
    %{"name" => "AWS_SESSION_TOKEN", "optional" => true},
    %{"name" => "AWS_REGION", "optional" => true}
  ]

  @packages [
    %{
      "name" => "claude_code",
      "description" =>
        "Anthropic Claude Code CLI with the current working directory mounted at /instance and host Claude credentials shared in.",
      "image" => "dockd/claude-code:latest",
      "shell" => "claude",
      "build" => %{"dockerfile" => "Dockerfile"},
      "mounts" => [
        "${PWD}:/instance",
        "${HOME}/.claude:/root/.claude",
        "${HOME}/.claude.json:/root/.claude.json"
      ],
      "env" => @env
    },
    %{
      "name" => "claude_code_live_workspace",
      "description" =>
        "Claude Code CLI with the current working directory live-mounted at /instance and host Claude credentials shared in.",
      "image" => "dockd/claude-code:latest",
      "shell" => "claude",
      "build" => %{"dockerfile" => "Dockerfile"},
      "mounts" => [
        "${PWD}:/instance",
        "${HOME}/.claude:/root/.claude",
        "${HOME}/.claude.json:/root/.claude.json"
      ],
      "env" => @env
    },
    %{
      "name" => "claude_code_isolated_workspace",
      "description" =>
        "Claude Code CLI running in an isolated workspace with the host project copied into /instance/project and an output volume mounted from ~/dockd-output.",
      "image" => "dockd/claude-code:latest",
      "shell" => "claude",
      "build" => %{"dockerfile" => "Dockerfile"},
      "env" => @env,
      "mounts" => [
        "${HOME}/dockd-output:/instance/output"
      ],
      "copy" => [
        %{"src" => "${PWD}", "dest" => "/instance/project"}
      ],
      "steps" => [
        %{
          "label" => "scaffold output dir",
          "cmd" => ["mkdir", "-p", "/instance/output"]
        }
      ]
    },
    %{
      "name" => "claude_code_repo_workspace",
      "description" =>
        "Claude Code CLI in a workspace populated by cloning ${DOCKD_REPO_URL} into /instance/repo with an output volume mounted from ~/dockd-output.",
      "image" => "dockd/claude-code:latest",
      "shell" => "claude",
      "build" => %{"dockerfile" => "Dockerfile"},
      "env" => @env,
      "mounts" => [
        "${HOME}/dockd-output:/instance/output"
      ],
      "repos" => [
        %{
          "url" => "${DOCKD_REPO_URL}",
          "ref" => "${DOCKD_REPO_REF:-main}",
          "dest" => "/instance/repo"
        }
      ],
      "steps" => [
        %{
          "label" => "scaffold output dir",
          "cmd" => ["mkdir", "-p", "/instance/output"]
        }
      ]
    }
  ]

  @type generated_package :: %{
          name: binary(),
          path: Path.t(),
          files: [Path.t()]
        }

  @doc """
  Returns the Claude Code package names this app can generate.
  """
  @spec package_names() :: [binary()]
  def package_names, do: Enum.map(@packages, & &1["name"])

  @doc """
  Returns the package root used by the generator.

  Resolution order is `opts[:packages_path]`, `DOCKD_PACKAGES_PATH`,
  `config :dockd_claude_code, :packages_path`, then `~/.dockd/packages`.
  """
  @spec packages_root(keyword()) :: Path.t()
  def packages_root(opts \\ []) when is_list(opts) do
    Keyword.get(opts, :packages_path) ||
      System.get_env("DOCKD_PACKAGES_PATH") ||
      Application.get_env(:dockd_claude_code, :packages_path) ||
      Path.join(System.user_home!(), ".dockd/packages")
  end

  @doc """
  Writes all Claude Code packages into the resolved package root.

  Options:

    * `:packages_path` - destination package root.
    * `:force` - replace existing package directories. Defaults to `false`.
  """
  @spec generate(keyword()) :: {:ok, [generated_package()]} | {:error, binary()}
  def generate(opts \\ []) when is_list(opts) do
    packages_path = packages_root(opts)
    force? = Keyword.get(opts, :force, false)

    with :ok <- ensure_root(packages_path) do
      Enum.reduce_while(@packages, {:ok, []}, fn package, {:ok, acc} ->
        case generate_package(package, packages_path, force?) do
          {:ok, generated} -> {:cont, {:ok, [generated | acc]}}
          {:error, message} -> {:halt, {:error, message}}
        end
      end)
      |> case do
        {:ok, packages} -> {:ok, Enum.reverse(packages)}
        {:error, message} -> {:error, message}
      end
    end
  end

  defp ensure_root(packages_path) do
    case File.mkdir_p(packages_path) do
      :ok ->
        :ok

      {:error, reason} ->
        {:error, "could not create packages path #{packages_path}: #{inspect(reason)}"}
    end
  end

  defp generate_package(%{"name" => name} = package, packages_path, force?) do
    target_dir = Path.join(packages_path, name)

    if File.exists?(target_dir) and not force? do
      {:error,
       "package #{inspect(name)} already exists at #{target_dir}; pass --force to replace it"}
    else
      write_package(package, target_dir)
    end
  end

  defp write_package(%{"name" => name} = package, target_dir) do
    _ = File.rm_rf(target_dir)

    with :ok <- mkdir(target_dir),
         :ok <- write_json(Path.join(target_dir, "package.json"), package),
         :ok <- write_file(Path.join(target_dir, "Dockerfile"), @dockerfile) do
      {:ok,
       %{
         name: name,
         path: target_dir,
         files: [Path.join(target_dir, "package.json"), Path.join(target_dir, "Dockerfile")]
       }}
    end
  end

  defp mkdir(path) do
    case File.mkdir_p(path) do
      :ok ->
        :ok

      {:error, reason} ->
        {:error, "could not create package directory #{path}: #{inspect(reason)}"}
    end
  end

  defp write_json(path, package) do
    write_file(path, JSON.encode!(package))
  end

  defp write_file(path, content) do
    case File.write(path, content) do
      :ok -> :ok
      {:error, reason} -> {:error, "could not write #{path}: #{inspect(reason)}"}
    end
  end
end

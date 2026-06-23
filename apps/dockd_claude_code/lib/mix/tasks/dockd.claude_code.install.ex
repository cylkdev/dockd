defmodule Mix.Tasks.Dockd.ClaudeCode.Install do
  @moduledoc """
  Generates Claude Code dockd packages into the configured package root.

  ## Usage

      mix dockd.claude_code.install [--packages-path DIR] [--force]

  When `--packages-path` is omitted, packages are written to
  `~/.dockd/packages`, unless `DOCKD_PACKAGES_PATH` or
  `config :dockd_claude_code, :packages_path` is set.
  """

  @shortdoc "Generate Claude Code dockd packages"

  use Mix.Task

  @impl Mix.Task
  def run(args) do
    {opts, positional, invalid} =
      OptionParser.parse(args,
        strict: [
          packages_path: :string,
          force: :boolean
        ]
      )

    cond do
      invalid != [] ->
        Mix.raise("Invalid option: #{format_invalid(invalid)}")

      positional != [] ->
        Mix.raise("Usage: mix dockd.claude_code.install [--packages-path DIR] [--force]")

      true ->
        install(opts)
    end
  end

  defp install(opts) do
    case Dockd.ClaudeCode.Packages.generate(opts) do
      {:ok, packages} ->
        Enum.each(packages, fn %{name: name, path: path} ->
          Mix.shell().info("Generated #{name} at #{path}")
        end)

      {:error, message} ->
        Mix.raise(message)
    end
  end

  defp format_invalid([{flag, value} | _]) do
    Enum.join([to_string(flag), value], " ")
  end
end

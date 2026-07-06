defmodule Dockd.Tui.Action do
  @moduledoc """
  Dispatches one dashboard command through a `Dockd.Tui.Data` implementation
  and turns the result into a human-ready summary line. `perform/3` is the
  synchronous core (unit-tested); `run/4` wraps it in a `Task` and streams
  `{:action, ref, stage, payload}` messages back to the dashboard so the render
  loop never blocks.
  """

  @spec run(pid(), module(), {atom(), term()}, keyword()) :: reference()
  def run(target, data_mod, spec, opts) do
    ref = make_ref()
    send(target, {:action, ref, :started, label(spec)})

    Task.start(fn ->
      try do
        case perform(data_mod, spec, opts) do
          {:done, summary} -> send(target, {:action, ref, :done, summary})
          {:error, message} -> send(target, {:action, ref, :error, message})
        end
      rescue
        e -> send(target, {:action, ref, :error, Exception.message(e)})
      end
    end)

    ref
  end

  @spec perform(module(), {atom(), term()}, keyword()) :: {:done, binary()} | {:error, binary()}
  def perform(data_mod, {:stop, name}, opts),
    do: lifecycle(data_mod.stop(name, opts), "stopped #{name}")

  def perform(data_mod, {:start, name}, opts),
    do: lifecycle(data_mod.start(name, opts), "started #{name}")

  def perform(data_mod, {:restart, name}, opts),
    do: lifecycle(data_mod.restart(name, opts), "restarted #{name}")

  def perform(data_mod, {:destroy, name}, opts),
    do: lifecycle(data_mod.destroy(name, opts), "destroyed #{name}")

  def perform(data_mod, {:logs, name}, opts) do
    case data_mod.logs(name, opts) do
      {:ok, binary} -> {:done, "logs #{name}:\n" <> binary}
      other -> {:error, error_message(other, "logs")}
    end
  end

  def perform(data_mod, {:inspect, name}, opts) do
    case data_mod.inspect(name, opts) do
      {:ok, map} -> {:done, "inspect #{name}:\n" <> inspect(map, pretty: true)}
      other -> {:error, error_message(other, "inspect")}
    end
  end

  def perform(data_mod, {:instance_run, values}, opts) do
    case data_mod.run(values, opts) do
      {:ok, instance} -> {:done, "created #{instance.name}"}
      other -> {:error, error_message(other, "run")}
    end
  end

  def perform(data_mod, {:package_install, %{source: source}}, opts) do
    case data_mod.install_package(source, opts) do
      {:ok, []} -> {:done, "No packages found in repository"}
      {:ok, names} -> {:done, "Installed #{length(names)} package(s): #{Enum.join(names, ", ")}"}
      other -> {:error, error_message(other, "install")}
    end
  end

  def perform(data_mod, {:info, _}, opts) do
    case data_mod.info(opts) do
      {:ok, map} -> {:done, "info:\n" <> inspect(map, pretty: true)}
      other -> {:error, error_message(other, "info")}
    end
  end

  def perform(data_mod, {:package_show, _}, opts) do
    case data_mod.list_packages(opts) do
      {:ok, []} ->
        {:done, "No packages installed"}

      {:ok, packages} ->
        {:done, "Installed packages: " <> Enum.map_join(packages, ", ", & &1.name)}

      other ->
        {:error, error_message(other, "package show")}
    end
  end

  def perform(data_mod, {:shell, name}, opts) do
    case data_mod.open_shell_window(name, opts) do
      :ok -> {:done, "opened a shell for #{name} in a new window"}
      other -> {:error, error_message(other, "shell")}
    end
  end

  def perform(_data_mod, {:ssh_generate, values}, _opts) do
    dir = blank_to_nil(Map.get(values, :output_dir)) || File.cwd!()

    case Dockd.Ssh.generate_script(dir, []) do
      {:ok, %{path: path}} -> {:done, "Generated #{path}"}
      {:error, msg} -> {:error, msg}
    end
  end

  def perform(_data_mod, {:ssh_install, values}, _opts) do
    with host when is_binary(host) and host != "" <- Map.get(values, :user_at_host, ""),
         {:ok, {source, desc}} <- Dockd.Ssh.resolve_source(nil),
         {:ok, %{remote_path: rp}} <-
           Dockd.Ssh.install_script(source, host, remote_opts(values)) do
      {:done, "Installed #{desc} → #{host}:#{rp}"}
    else
      "" -> {:error, "user@host is required"}
      {:error, message} -> {:error, to_message(message)}
    end
  end

  @spec label({atom(), term()}) :: binary()
  def label({verb, name}) when is_binary(name), do: "#{verb} #{name}"
  def label({verb, %{} = _values}), do: to_string(verb)

  # --- internal ---

  defp lifecycle(:ok, summary), do: {:done, summary}
  defp lifecycle(other, _summary), do: {:error, error_message(other, "action")}

  defp error_message({:error, %Dockd.Error{} = err}, _phase),
    do: "#{err.phase}: #{Exception.message(err)}"

  defp error_message({:error, reason}, phase), do: "#{phase}: #{to_message(reason)}"
  defp error_message(other, phase), do: "#{phase}: #{to_message(other)}"

  defp to_message(msg) when is_binary(msg), do: msg
  defp to_message(other), do: inspect(other)

  defp remote_opts(values) do
    Enum.reduce([:remote_path, :identity, :port], [], fn key, acc ->
      case blank_to_nil(Map.get(values, key)) do
        nil -> acc
        v -> Keyword.put(acc, key, v)
      end
    end)
  end

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(""), do: nil
  defp blank_to_nil(v), do: v
end

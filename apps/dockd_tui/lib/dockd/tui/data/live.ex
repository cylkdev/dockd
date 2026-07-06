defmodule Dockd.Tui.Data.Live do
  @moduledoc "Production `Dockd.Tui.Data`: delegates to the `Dockd.*` core API."
  @behaviour Dockd.Tui.Data

  alias Dockd.ApplyResult
  alias Dockd.Spec

  @impl true
  def list(opts), do: Dockd.list(opts)

  @impl true
  def logs(name, opts), do: Dockd.logs(name, opts)

  @impl true
  def inspect(name, opts), do: Dockd.inspect(name, opts)

  @impl true
  def stop(name, opts), do: Dockd.stop(name, opts)

  @impl true
  def start(name, opts), do: Dockd.start(name, opts)

  @impl true
  def restart(name, opts), do: Dockd.restart(name, opts)

  @impl true
  def destroy(name, opts), do: Dockd.destroy(name, opts)

  @impl true
  def run(values, opts) do
    image = Map.get(values, :image) || ""
    spec_opts = Enum.reject([name: values[:name], tag: values[:tag]], fn {_k, v} -> is_nil(v) end)

    case Dockd.apply(Spec.from_opts(image, spec_opts), opts) do
      {:ok, %ApplyResult{instance: instance}} -> {:ok, instance}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def install_package(source, opts), do: Dockd.Packages.install_from_git(source, opts)

  @impl true
  def info(opts), do: Dockd.info(opts)

  @impl true
  def list_packages(opts), do: {:ok, Dockd.Packages.list(opts)}

  @impl true
  def open_shell_window(%Dockd.Instance{} = instance, opts),
    do: Dockd.Shell.open_window(instance, opts)

  def open_shell_window(name, opts) when is_binary(name) do
    case Dockd.get(name, opts) do
      {:ok, instance} -> Dockd.Shell.open_window(instance, opts)
      {:error, reason} -> {:error, reason}
    end
  end
end

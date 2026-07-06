defmodule DockdCLI.Commands.Instance.List do
  @moduledoc """
  Lists dockd-managed Docker containers.

  Calls `Dockd.list/1` and prints one row per instance with name, image,
  status, and short container ID. When no instances are running on the
  daemon, prints `No dockd instances.` and exits 0.
  """

  alias Dockd.Instance
  alias DockdCLI.Output
  alias DockdCLI.Json

  @spec run(map(), keyword()) :: :ok | {:error, term()}
  def run(_args, opts), do: render(Dockd.list(opts))

  @doc false
  @spec render({:ok, [Instance.t()]} | {:error, term()}) :: :ok | {:error, term()}
  def render({:ok, []}), do: Output.info("No dockd instances.")

  def render({:ok, instances}) do
    rows = Enum.map(instances, &row/1)
    Output.table(rows, {"NAME", "IMAGE", "STATUS", "ID"})
  end

  def render({:error, %Dockd.Error{} = err}), do: {:error, Exception.message(err)}
  def render({:error, err}), do: {:error, err}

  @spec run_json(map(), keyword()) :: :ok | {:error, term()}
  def run_json(_args, opts), do: render_json(Dockd.list(opts))

  @doc false
  @spec render_json({:ok, [Instance.t()]} | {:error, term()}) :: :ok | {:error, term()}
  def render_json({:ok, instances}) do
    Output.json(Enum.map(instances, &Json.instance/1))
  end

  def render_json({:error, err}), do: {:error, err}

  defp row(%Instance{} = instance) do
    {
      Instance.short_name(instance),
      instance.image || "",
      if(instance.running?, do: "running", else: "stopped"),
      short_id(instance.id)
    }
  end

  defp short_id(nil), do: ""
  defp short_id(id) when is_binary(id), do: String.slice(id, 0, 12)
end

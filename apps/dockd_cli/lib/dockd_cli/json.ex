defmodule DockdCLI.Json do
  @moduledoc "Curated CLI-to-JSON field mappings. Owns the `--json` output contract."

  alias Dockd.Instance

  @spec instance(Instance.t()) :: map()
  def instance(%Instance{} = inst) do
    %{
      name: Instance.short_name(inst),
      image: inst.image,
      status: if(inst.running?, do: "running", else: "stopped"),
      id: inst.id
    }
  end

  @spec action(binary(), binary()) :: map()
  def action(name, action) when is_binary(name) and is_binary(action),
    do: %{name: name, action: action, status: "ok"}
end

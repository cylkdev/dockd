defmodule Dockd.Tui.View.Form do
  @moduledoc """
  Field-editor state + rendering for a form-driven command. Pure functions
  return a new form; the dashboard owns the form in its state and routes key
  events through `type/2`, `backspace/1`, `next/1`, `prev/1`. `validate/1`
  enforces required fields; `values/1` feeds `Dockd.Tui.Action`.
  """

  @type t :: %{command: map(), values: %{atom() => binary()}, index: non_neg_integer()}

  @spec new(map()) :: t()
  def new(command) do
    values = Map.new(command.fields, fn f -> {f.key, ""} end)
    %{command: command, values: values, index: 0}
  end

  @spec type(t(), binary()) :: t()
  def type(form, grapheme) do
    key = focused_key(form)
    update_in(form.values[key], &((&1 || "") <> grapheme))
  end

  @spec backspace(t()) :: t()
  def backspace(form) do
    key = focused_key(form)
    update_in(form.values[key], fn v -> String.slice(v || "", 0..-2//1) end)
  end

  @spec next(t()) :: t()
  def next(form), do: %{form | index: min(form.index + 1, length(form.command.fields) - 1)}

  @spec prev(t()) :: t()
  def prev(form), do: %{form | index: max(form.index - 1, 0)}

  @spec validate(t()) :: :ok | {:error, binary()}
  def validate(form) do
    missing =
      Enum.find(form.command.fields, fn f ->
        f.required and blank?(form.values[f.key])
      end)

    case missing do
      nil -> :ok
      field -> {:error, "#{field.label} is required"}
    end
  end

  @spec values(t()) :: %{atom() => binary()}
  def values(form), do: form.values

  @spec render(t()) :: binary()
  def render(form) do
    header = "── #{form.command.label} ──"

    field_lines =
      form.command.fields
      |> Enum.with_index()
      |> Enum.map(fn {f, i} ->
        marker = if i == form.index, do: "> ", else: "  "
        req = if f.required, do: "*", else: " "
        "#{marker}#{req}#{f.label}: #{form.values[f.key]}"
      end)

    Enum.join([header | field_lines] ++ ["", "Enter submit · Esc cancel"], "\n")
  end

  defp focused_key(form) do
    form.command.fields |> Enum.at(form.index) |> Map.fetch!(:key)
  end

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(_), do: false
end

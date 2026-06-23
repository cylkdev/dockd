defmodule Dockd.Spec.Source do
  @moduledoc """
  File IO for `Dockd.Spec` JSON documents.

  The single responsibility of this module is reading a `package.json`
  (or any other spec JSON file) from disk and returning its raw body.
  Errors are wrapped as `:validate`-phase `Dockd.Error` values so every
  step of the spec-loading pipeline produces the same error shape.

  Knows nothing about JSON. Downstream parsing belongs to
  `Dockd.Spec.Json`.
  """

  alias Dockd.Error

  @doc """
  Reads the file at `path` and returns its raw contents.

  Returns `{:error, %Dockd.Error{phase: :validate}}` if the file cannot
  be read (missing, permission denied, etc.).
  """
  @spec read_file(Path.t()) :: {:ok, binary()} | {:error, Error.t()}
  def read_file(path) when is_binary(path) do
    case File.read(path) do
      {:ok, body} ->
        {:ok, body}

      {:error, reason} ->
        {:error,
         %Error{
           phase: :validate,
           message: "could not read file #{path}: #{:file.format_error(reason)}"
         }}
    end
  end
end

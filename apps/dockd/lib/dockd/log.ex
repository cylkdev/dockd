defmodule Dockd.Log do
  @moduledoc false
  require Logger

  @spec debug(prefix :: binary(), message :: binary()) :: :ok
  def debug(prefix, message) do
    prefix
    |> format_message(message)
    |> Logger.debug()
  end

  @spec info(prefix :: binary(), message :: binary()) :: :ok
  def info(prefix, message) do
    prefix
    |> format_message(message)
    |> Logger.info()
  end

  @spec warning(prefix :: binary(), message :: binary()) :: :ok
  def warning(prefix, message) do
    prefix
    |> format_message(message)
    |> Logger.warning()
  end

  @spec error(prefix :: binary(), message :: binary()) :: :ok
  def error(prefix, message) do
    prefix
    |> format_message(message)
    |> Logger.error()
  end

  defp format_message(prefix, message) do
    "[#{prefix}] #{message}"
  end
end

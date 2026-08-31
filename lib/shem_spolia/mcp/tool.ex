defmodule ShemSpolia.MCP.Tool do
  @moduledoc """
  Behaviour for an `audit.*` tool exposed over MCP.
  """

  @callback name() :: String.t()
  @callback description() :: String.t()
  @callback input_schema() :: map()
  @callback call(args :: map()) :: {:ok, term()} | {:error, String.t()}

  defmacro __using__(_opts) do
    quote do
      @behaviour ShemSpolia.MCP.Tool
    end
  end
end
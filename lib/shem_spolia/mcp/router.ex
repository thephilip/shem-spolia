defmodule ShemSpolia.MCP.Router do
  @moduledoc """
  Dispatches MCP `tools/call` to an `audit.*` tool module.
  """

  @tools [
    ShemSpolia.MCP.Tools.VerifyChain,
    ShemSpolia.MCP.Tools.ExportBundle,
    ShemSpolia.MCP.Tools.ForkHere,
    ShemSpolia.MCP.Tools.Recall
  ]

  @spec tools() :: [module()]
  def tools, do: @tools

  @spec manifest() :: [map()]
  def manifest do
    Enum.map(@tools, fn mod ->
      %{
        "name" => mod.name(),
        "description" => mod.description(),
        "inputSchema" => mod.input_schema()
      }
    end)
  end

  @spec dispatch(String.t(), map()) :: {:ok, term()} | {:error, String.t()}
  def dispatch(name, args) do
    case Enum.find(@tools, &(&1.name() == name)) do
      nil ->
        {:error, "unknown tool: #{name}"}

      mod ->
        try do
          mod.call(args || %{})
        rescue
          e -> {:error, Exception.message(e)}
        catch
          kind, reason -> {:error, "#{kind}: #{inspect(reason)}"}
        end
    end
  end
end
defmodule ShemSpolia.ToolSources do
  @moduledoc """
  Resolves a tool NAME (as recorded in `:agent_tool_called` events) to its
  source, so `Attest` can put the exact bytes in the bundle.

  Spolia has no tool registry of its own — it audits agents that own their
  tools. Resolution is therefore pluggable and **empty by default**: every
  tool exports as `status: "missing"` unless a resolver is configured.

      config :shem_spolia, :tool_source_resolver, fn name ->
        case MyRegistry.fetch(name) do
          {:ok, t} -> {:ok, %{source: t.source, ext: "py", runtime: "python"}}
          :error   -> :error
        end
      end

  A resolver returns `{:ok, %{source: binary, ext: String.t, runtime: String.t}}`
  or `:error`.

  KNOWN LIMIT (documented in spec.md): tools belonging to a third-party MCP
  server live on that server's machine and are not resolvable here. Those
  export as "missing" — the bundle names them and proves they were CALLED,
  but cannot carry their source.
  """

  @type resolved :: %{source: binary(), ext: String.t(), runtime: String.t()}

  @spec resolve(String.t()) :: {:ok, resolved()} | :error
  def resolve(name) do
    case Application.get_env(:shem_spolia, :tool_source_resolver) do
      fun when is_function(fun, 1) -> normalize(fun.(name))
      {mod, f} when is_atom(mod) and is_atom(f) -> normalize(apply(mod, f, [name]))
      _ -> :error
    end
  end

  defp normalize({:ok, %{source: source} = r}) when is_binary(source) do
    {:ok,
     %{
       source: source,
       ext: Map.get(r, :ext, "txt"),
       runtime: Map.get(r, :runtime, "unknown")
     }}
  end

  defp normalize(_), do: :error
end
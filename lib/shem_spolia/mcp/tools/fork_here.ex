defmodule ShemSpolia.MCP.Tools.ForkHere do
  use ShemSpolia.MCP.Tool

  @impl true
  def name, do: "audit.fork_here"

  @impl true
  def description,
    do:
      "Create a counterfactual branch of a recorded session: copy history up to a chosen event, " <>
        "then append an alternative turn in place of what actually happened. The branch is a real " <>
        "hash-chained session — verify it and export a bundle from it like any other."

  @impl true
  def input_schema do
    %{
      "type" => "object",
      "properties" => %{
        "session_id" => %{"type" => "string", "description" => "Session to branch from."},
        "fork_point" => %{
          "type" => "string",
          "description" =>
            "Event id to branch at (inclusive). Omit to branch from the end of the session. " <>
              "audit.recall returns a usable fork_point with every hit."
        },
        "alt_response" => %{
          "type" => "object",
          "description" =>
            "The alternative turn to record instead, e.g. {\"content\": \"...\", \"tool_calls\": []}."
        }
      },
      "required" => ["session_id", "alt_response"]
    }
  end

  @impl true
  def call(%{"session_id" => session_id, "alt_response" => alt} = args) when is_map(alt) do
    case ShemSpolia.Fork.create(session_id, Map.get(args, "fork_point"), alt) do
      {:ok, result} ->
        {:ok, result}

      {:error, {:chain_broken, {:broken_at, id}}} ->
        {:error, "refusing to fork #{session_id}: chain broken at #{id}"}

      {:error, {:event_not_found, id}} ->
        {:error, "fork point not found in #{session_id}: #{id}"}

      {:error, :not_found} ->
        {:error, "session not found: #{session_id}"}

      {:error, reason} ->
        {:error, "fork failed: #{inspect(reason)}"}
    end
  end

  def call(%{"alt_response" => _}), do: {:error, "session_id is required"}
  def call(_), do: {:error, "session_id and alt_response are required"}
end
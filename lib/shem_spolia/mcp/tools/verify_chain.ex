defmodule ShemSpolia.MCP.Tools.VerifyChain do
  use ShemSpolia.MCP.Tool

  @impl true
  def name, do: "audit.verify_chain"

  @impl true
  def description,
    do:
      "Recompute the hash chain for a recorded session and report whether it is intact. " <>
        "Returns the first broken event id if it is not."

  @impl true
  def input_schema do
    %{
      "type" => "object",
      "properties" => %{
        "session_id" => %{"type" => "string", "description" => "Session to verify."}
      },
      "required" => ["session_id"]
    }
  end

  @impl true
  def call(%{"session_id" => session_id}) do
    case ShemSpolia.EventLog.verify_chain(session_id) do
      {:ok, :verified, n} ->
        {:ok, %{valid: true, kind: "verified", events: n, broken_at: nil}}

      {:ok, :verified_gc, %{pruned: p, replayable: r}} ->
        {:ok,
         %{valid: true, kind: "verified_gc", pruned: p, replayable: r, broken_at: nil}}

      {:ok, :legacy, n} ->
        {:ok, %{valid: true, kind: "legacy", events: n, broken_at: nil}}

      {:error, {:broken_at, id}} ->
        {:ok, %{valid: false, kind: "broken", broken_at: id}}

      {:error, :not_found} ->
        {:error, "session not found: #{session_id}"}
    end
  end

  def call(_), do: {:error, "session_id is required"}
end
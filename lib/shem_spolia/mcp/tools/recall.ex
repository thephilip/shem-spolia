defmodule ShemSpolia.MCP.Tools.Recall do
  use ShemSpolia.MCP.Tool

  alias ShemSpolia.EventLog
  alias ShemSpolia.Recall.{Index, Text}

  @snippet_chars 240

  @impl true
  def name, do: "audit.recall"

  @impl true
  def description,
    do:
      "Search past recorded sessions by meaning (BM25 over the hash-chained event log). " <>
        "Each hit carries a snippet, its event id, and the nearest preceding LLM turn — " <>
        "the point you would pass to audit.fork_here. Chain-broken sessions are never returned."

  @impl true
  def input_schema do
    %{
      "type" => "object",
      "properties" => %{
        "query" => %{"type" => "string", "description" => "What to look for."},
        "limit" => %{
          "type" => "integer",
          "description" => "Max hits to return. Default 10.",
          "default" => 10
        },
        "session_id" => %{
          "type" => "string",
          "description" => "Optional: restrict results to a single session."
        }
      },
      "required" => ["query"]
    }
  end

  @impl true
  def call(%{"query" => query} = args) do
    limit = normalize_limit(Map.get(args, "limit"))
    only = Map.get(args, "session_id")

    # over-fetch when filtering to one session, so the filter has candidates
    fetch = if only, do: limit * 10, else: limit

    %{hits: hits, skipped: skipped, indexed_sessions: n} = Index.search(query, fetch)

    hits =
      hits
      |> then(fn h -> if only, do: Enum.filter(h, &(&1.session_id == only)), else: h end)
      |> Enum.take(limit)
      |> Enum.map(&decorate/1)

    {:ok, %{hits: hits, skipped: skipped, indexed_sessions: n}}
  end

  def call(_), do: {:error, "query is required"}

  defp normalize_limit(n) when is_integer(n) and n > 0, do: min(n, 100)
  defp normalize_limit(_), do: 10

  # Attach the snippet, event type, and the fork point: the nearest
  # :llm_call_completed at or before the hit. That is the event a caller
  # replays from, so recall hands it over rather than making them hunt.
  defp decorate(%{session_id: sid, event_id: eid, score: score}) do
    base = %{session_id: sid, event_id: eid, score: score}

    case EventLog.read_session_events(sid) do
      {:ok, events} ->
        idx = Enum.find_index(events, &(&1.id == eid))

        event = idx && Enum.at(events, idx)

        fork_point =
          if idx do
            events
            |> Enum.take(idx + 1)
            |> Enum.reverse()
            |> Enum.find(&(&1.type == :llm_call_completed))
            |> then(& &1 && &1.id)
          end

        base
        |> Map.put(:type, event && to_string(event.type))
        |> Map.put(:timestamp, event && DateTime.to_iso8601(event.timestamp))
        |> Map.put(:snippet, event && snippet(event))
        |> Map.put(:fork_point, fork_point)

      _ ->
        base
    end
  end

  defp snippet(event) do
    event.payload
    |> Text.flatten()
    |> String.replace(~r/\s+/u, " ")
    |> String.trim()
    |> String.slice(0, @snippet_chars)
  end
end
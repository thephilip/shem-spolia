defmodule ShemSpolia.Recall.Index do
  @moduledoc """
  In-memory inverted index over all session EventLogs. Built lazily on the
  first search and cached per session file by `{mtime, size}`; changed or new
  files are re-scanned on the next search, so the index can never be
  stale-wrong.

  A chain-broken log is tampered evidence: it is skipped, reported in
  `skipped`, and never served as memory.

  ponytail: full per-file rescan + unbounded memory — persistent index / size
  cap when a real corpus makes this slow or big. The corpus is the on-disk DETS
  events directory only; sessions stored via MnesiaStore are not yet indexed.
  """

  use GenServer

  alias ShemSpolia.Recall.{Scanner, Text}

  @call_timeout 30_000

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, %{}, name: Keyword.get(opts, :name, __MODULE__))
  end

  @spec search(GenServer.server(), String.t(), pos_integer()) :: %{
          hits: [%{session_id: String.t(), event_id: String.t(), score: float()}],
          skipped: [%{session_id: String.t(), reason: String.t()}],
          indexed_sessions: non_neg_integer()
        }
  def search(server \\ __MODULE__, query, limit) do
    GenServer.call(server, {:search, query, limit}, @call_timeout)
  end

  @impl true
  def init(_), do: {:ok, %{files: %{}}}

  @impl true
  def handle_call({:search, query, limit}, _from, state) do
    {state, skipped} = refresh(state)

    docs =
      for {sid, %{docs: docs}} <- state.files,
          {event_id, tokens} <- docs,
          into: %{} do
        {{sid, event_id}, tokens}
      end

    hits =
      Text.rank(Text.tokenize(query), docs)
      |> Enum.take(limit)
      |> Enum.map(fn {{sid, event_id}, score} ->
        %{session_id: sid, event_id: event_id, score: Float.round(score, 4)}
      end)

    {:reply, %{hits: hits, skipped: skipped, indexed_sessions: map_size(state.files)}, state}
  end

  # Re-scan new/changed session files; drop deleted ones. Returns {state, skipped}.
  defp refresh(state) do
    current = Scanner.sessions()
    current_ids = MapSet.new(current, & &1.session_id)

    kept = Map.filter(state.files, fn {sid, _} -> MapSet.member?(current_ids, sid) end)

    Enum.reduce(current, {%{files: kept}, []}, fn %{session_id: sid, cache_key: key},
                                                  {st, skipped} ->
      case st.files do
        %{^sid => %{key: ^key}} ->
          {st, skipped}

        _ ->
          case index_session(sid) do
            {:ok, docs} ->
              {put_in(st.files[sid], %{key: key, docs: docs}), skipped}

            {:error, reason} ->
              {st, [%{session_id: sid, reason: inspect(reason)} | skipped]}
          end
      end
    end)
  end

  defp index_session(session_id) do
    with {:ok, events} <- Scanner.events(session_id),
         :ok <- check_chain(session_id) do
      docs =
        Map.new(events, fn e ->
          {e.id, Text.tokenize(Text.flatten(e.payload)) ++ Text.tokenize(to_string(e.type))}
        end)

      {:ok, docs}
    end
  end

  # A chain-broken log is tampered/corrupt evidence — skip it and say so,
  # never serve it as memory. Runs only when a file changed, so the hashing
  # cost is rare.
  defp check_chain(session_id) do
    case ShemSpolia.EventLog.verify_chain(session_id) do
      {:error, {:broken_at, event_id}} -> {:error, {:broken_chain_at, event_id}}
      _ -> :ok
    end
  end
end
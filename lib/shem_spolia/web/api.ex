defmodule ShemSpolia.Web.API do
  @moduledoc """
  JSON handlers over the same primitives the MCP tools expose.

  Deliberately the same *primitives*, not the same *code path*: the MCP tools
  answer to a model and shape their results for one, while these answer to a
  browser. Both call `EventLog` / `Attest` / `Fork` / `Recall` directly, so
  neither can drift into being the privileged one.

  Every response is a map, encoded by the router. Handlers return
  `{status, map}`.
  """

  alias ShemSpolia.{Attest, EventLog, Fork, Recall}

  @doc "GET /api/sessions — every known session with its chain verdict."
  def sessions do
    sessions =
      EventLog.known_session_ids()
      |> Enum.map(&session_summary/1)
      |> Enum.sort_by(& &1.last_at, :desc)

    {200, %{sessions: sessions, count: length(sessions)}}
  end

  @doc "GET /api/sessions/:id/events — the full chain, oldest first."
  def events(session_id) do
    case EventLog.read_session_events(session_id) do
      {:ok, events} ->
        {200,
         %{
           session_id: session_id,
           events: Enum.map(events, &event_view/1),
           count: length(events),
           verify: verdict(session_id)
         }}

      {:error, _} ->
        {404, %{error: "session not found", session_id: session_id}}
    end
  end

  @doc "GET /api/sessions/:id/verify — recompute the chain."
  def verify(session_id) do
    case verdict(session_id) do
      %{state: "not_found"} = v -> {404, Map.put(v, :session_id, session_id)}
      v -> {200, Map.put(v, :session_id, session_id)}
    end
  end

  @doc "POST /api/sessions/:id/attest — write a bundle, return its path + manifest."
  def attest(session_id, params) do
    out = params["out_dir"] || default_bundle_dir()

    case Attest.build(session_id, out: out) do
      {:ok, dir} ->
        {201,
         %{
           session_id: session_id,
           bundle_path: dir,
           manifest: read_manifest(dir),
           verify_command: "python3 #{Path.join(dir, "verify.py")} #{dir}",
           files: dir |> File.ls!() |> Enum.sort()
         }}

      {:error, {:chain_broken, {:broken_at, event_id}}} ->
        {409, %{error: "chain broken", broken_at: event_id, session_id: session_id}}

      {:error, :not_found} ->
        {404, %{error: "session not found", session_id: session_id}}

      {:error, reason} ->
        {422, %{error: inspect(reason), session_id: session_id}}
    end
  end

  @doc "POST /api/sessions/:id/fork — branch at an event with an alternative turn."
  def fork(session_id, params) do
    alt = params["alt_response"]
    point = params["fork_point"]

    cond do
      not is_map(alt) ->
        {422, %{error: "alt_response must be a JSON object"}}

      true ->
        case Fork.create(session_id, point, alt) do
          {:ok, result} ->
            {201, Map.put(result, :verify, verdict(result.fork_session_id))}

          {:error, {:chain_broken, {:broken_at, event_id}}} ->
            {409, %{error: "refusing to fork a broken chain", broken_at: event_id}}

          {:error, {:event_not_found, id}} ->
            {404, %{error: "fork point not in this session", fork_point: id}}

          {:error, :not_found} ->
            {404, %{error: "session not found", session_id: session_id}}

          {:error, reason} ->
            {422, %{error: inspect(reason)}}
        end
    end
  end

  @doc "GET /api/recall?q=...&limit=N — BM25 across hash-verified sessions."
  def recall(params) do
    query = String.trim(params["q"] || "")
    limit = to_int(params["limit"], 20)

    if query == "" do
      {422, %{error: "q is required"}}
    else
      result = Recall.Index.search(query, limit)

      {200,
       %{
         query: query,
         hits: enrich_hits(result.hits),
         skipped: result.skipped,
         indexed_sessions: result.indexed_sessions
       }}
    end
  end

  @doc "GET /api/stats — headline numbers for the status bar."
  def stats do
    ids = EventLog.known_session_ids()
    verdicts = Enum.map(ids, &verdict/1)

    {200,
     %{
       sessions: length(ids),
       verified: Enum.count(verdicts, &(&1.state == "verified")),
       broken: Enum.count(verdicts, &(&1.state == "broken")),
       legacy: Enum.count(verdicts, &(&1.state == "legacy")),
       events: verdicts |> Enum.map(& &1.count) |> Enum.sum(),
       needle: ShemSpolia.Needle.available?(),
       log_path: EventLog.event_log_path(),
       version: to_string(Application.spec(:shem_spolia, :vsn))
     }}
  end

  # ── shared shaping ───────────────────────────────────────────────────────

  @doc """
  The chain verdict as flat JSON.

  `state` is the single field the UI switches on; the rest is detail. Note
  `legacy` and `broken` are NOT the same claim — legacy means unhashed history
  we cannot speak to, broken means we hashed it and the hash disagrees. Folding
  them into one "not verified" state would be the lie this whole tool exists to
  avoid.
  """
  @spec verdict(String.t()) :: map()
  def verdict(session_id) do
    case EventLog.verify_chain(session_id) do
      {:ok, :verified, n} ->
        %{state: "verified", count: n, detail: nil, broken_at: nil}

      {:ok, :verified_gc, %{pruned: p, replayable: r}} ->
        %{
          state: "verified",
          count: r,
          detail: "#{p} pruned behind a digest anchor",
          broken_at: nil,
          pruned: p
        }

      {:ok, :legacy, n} when is_integer(n) ->
        %{state: "legacy", count: n, detail: "unhashed prefix", broken_at: nil}

      {:ok, :legacy, %{replayable: r}} ->
        %{state: "legacy", count: r, detail: "unhashed prefix", broken_at: nil}

      {:error, {:broken_at, event_id}} ->
        %{state: "broken", count: 0, detail: "hash mismatch", broken_at: event_id}

      {:error, :not_found} ->
        %{state: "not_found", count: 0, detail: nil, broken_at: nil}
    end
  end

  defp session_summary(session_id) do
    events =
      case EventLog.read_session_events(session_id) do
        {:ok, es} -> es
        _ -> []
      end

    first = List.first(events)
    last = List.last(events)
    fork = Enum.find(events, &(&1.type == :fork_created))

    %{
      id: session_id,
      verify: verdict(session_id),
      events: length(events),
      first_at: first && DateTime.to_iso8601(first.timestamp),
      last_at: (last && DateTime.to_iso8601(last.timestamp)) || "",
      head: last && last.hash,
      types: events |> Enum.map(&to_string(&1.type)) |> Enum.frequencies(),
      fork_of: fork && (fork.payload[:parent_session] || fork.payload["parent_session"]),
      meta: session_id in Recall.Scanner.meta_sessions()
    }
  end

  defp event_view(e) do
    %{
      id: e.id,
      seq: Map.get(e, :seq),
      type: to_string(e.type),
      timestamp: DateTime.to_iso8601(e.timestamp),
      parent_id: e.parent_id,
      hash: e.hash,
      payload: jsonable(e.payload)
    }
  end

  # A recall hit is only useful with the text it matched, and the UI should not
  # have to fetch a whole session per hit to show one line. `EventLog.event/2`
  # only answers for sessions with a live handle, and recall's corpus is mostly
  # on-disk sessions that were never opened — so read each session's events once
  # and index them locally rather than asking per hit.
  defp enrich_hits(hits) do
    by_session =
      hits
      |> Enum.map(& &1.session_id)
      |> Enum.uniq()
      |> Map.new(fn sid ->
        index =
          case EventLog.read_session_events(sid) do
            {:ok, events} -> Map.new(events, &{&1.id, &1})
            _ -> %{}
          end

        {sid, index}
      end)

    Enum.map(hits, fn %{session_id: sid, event_id: eid} = hit ->
      case by_session[sid][eid] do
        nil ->
          Map.merge(hit, %{type: nil, timestamp: nil, snippet: nil})

        e ->
          Map.merge(hit, %{
            type: to_string(e.type),
            timestamp: DateTime.to_iso8601(e.timestamp),
            snippet: e.payload |> Recall.Text.flatten() |> String.slice(0, 240)
          })
      end
    end)
  end

  defp read_manifest(dir) do
    with {:ok, raw} <- File.read(Path.join(dir, "manifest.json")),
         {:ok, decoded} <- Jason.decode(raw) do
      decoded
    else
      _ -> nil
    end
  end

  # Payloads hold whatever the recorder put there, including atoms, tuples,
  # PIDs and structs. Jason would raise on most of it; the browser only ever
  # needs a readable rendering, so anything not natively JSON becomes its
  # inspect form rather than a 500.
  defp jsonable(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp jsonable(%_{} = struct), do: struct |> Map.from_struct() |> jsonable()

  defp jsonable(map) when is_map(map),
    do: Map.new(map, fn {k, v} -> {to_string(k), jsonable(v)} end)

  defp jsonable(list) when is_list(list) do
    if List.ascii_printable?(list), do: to_string(list), else: Enum.map(list, &jsonable/1)
  end

  defp jsonable(t) when is_tuple(t), do: t |> Tuple.to_list() |> jsonable()
  defp jsonable(a) when is_atom(a) and not is_boolean(a) and not is_nil(a), do: to_string(a)
  defp jsonable(v) when is_binary(v) or is_number(v) or is_boolean(v) or is_nil(v), do: v
  defp jsonable(other), do: inspect(other)

  defp default_bundle_dir do
    dir = Path.join(EventLog.event_log_path(), "../bundles") |> Path.expand()
    File.mkdir_p!(dir)
    dir
  end

  defp to_int(nil, default), do: default

  defp to_int(v, default) when is_binary(v) do
    case Integer.parse(v) do
      {n, _} when n > 0 and n <= 200 -> n
      _ -> default
    end
  end

  defp to_int(v, _default) when is_integer(v), do: v
  defp to_int(_, default), do: default
end

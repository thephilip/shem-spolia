defmodule ShemSpolia.EventLog do
  @moduledoc """
  Append-only, hash-chained event log. One chain per session.

  Ported from Shem with the BEAM-side telemetry span dropped (spolia is a
  headless auditor; there is no metrics pipeline to feed). Everything that
  affects the chain — canonicalization, redaction, seq handling, GC ordering —
  is byte-for-byte the same logic, EXCEPT that `Chain` renders hashes in
  lowercase hex so the beam head and the portable head read the same way.
  """

  use GenServer

  alias ShemSpolia.EventLog.{Chain, Event, Session}

  # ── Client API ──────────────────────────────────────────────────────────────

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec start_session() :: {:ok, String.t()}
  def start_session, do: GenServer.call(__MODULE__, :start_session)

  @spec start_session(String.t()) :: {:ok, String.t()}
  def start_session(session_id), do: GenServer.call(__MODULE__, {:start_session, session_id})

  @spec end_session(String.t()) :: :ok | {:error, :session_not_found}
  def end_session(session_id), do: GenServer.call(__MODULE__, {:end_session, session_id})

  @doc """
  Mark a session ended (sets `ended_at`, so it no longer reads as active/LIVE)
  WITHOUT closing its store handle — so it stays readable. For static snapshots
  like forks that are finalized on creation, not running agents. Appends are
  still rejected (gated on `ended_at`).
  """
  @spec finalize(String.t()) :: :ok | {:error, :session_not_found}
  def finalize(session_id), do: GenServer.call(__MODULE__, {:finalize, session_id})

  @doc """
  Inverse of `finalize/1`: clears `ended_at` so appends are accepted again.
  Chain continuity is untouched — the chain simply grows from `last_hash`.
  `ended_at` means "no live writer", not "immutable"; immutability is the
  hash chain's job.
  """
  @spec reopen(String.t()) :: :ok | {:error, :session_not_found}
  def reopen(session_id), do: GenServer.call(__MODULE__, {:reopen, session_id})

  @spec list_sessions() :: {:ok, [Session.t()]}
  def list_sessions, do: GenServer.call(__MODULE__, :list_sessions)

  @spec stats() :: %{sessions: non_neg_integer(), total_events: non_neg_integer()}
  def stats, do: GenServer.call(__MODULE__, :stats)

  @spec append(String.t(), atom(), map(), String.t() | nil) ::
          {:ok, Event.t()} | {:error, :session_not_found | :session_ended}
  def append(session_id, type, payload, parent_id \\ nil) do
    payload = ShemSpolia.EventLog.Redact.redact(payload)
    GenServer.call(__MODULE__, {:append, session_id, type, payload, parent_id})
  end

  @spec events(String.t()) :: {:ok, [Event.t()]} | {:error, :session_not_found | :session_ended}
  def events(session_id), do: GenServer.call(__MODULE__, {:events, session_id})

  @spec scrub(String.t(), String.t()) ::
          :ok | {:error, :session_not_found | :session_ended | :event_not_found | :pruned}
  def scrub(session_id, after_event_id),
    do: GenServer.call(__MODULE__, {:scrub, session_id, after_event_id})

  @spec event(String.t(), String.t()) ::
          {:ok, Event.t()} | {:error, :session_not_found | :session_ended | :not_found | :pruned}
  def event(session_id, event_id),
    do: GenServer.call(__MODULE__, {:event, session_id, event_id})

  @spec read_session_events(String.t()) :: {:ok, [Event.t()]} | {:error, :not_found}
  def read_session_events(session_id),
    do: GenServer.call(__MODULE__, {:read_session_events, session_id})

  @spec verify_chain(String.t()) ::
          {:ok, :verified | :legacy, non_neg_integer()}
          | {:ok, :verified_gc | :legacy, %{pruned: non_neg_integer(), replayable: non_neg_integer()}}
          | {:error, {:broken_at, String.t()} | :not_found}
  def verify_chain(session_id) do
    case read_session_events(session_id) do
      {:ok, events} ->
        digest =
          case get_digest(session_id) do
            {:ok, d} -> d
            _ -> nil
          end

        Chain.verify(events, session_id, digest)

      {:error, _} ->
        {:error, :not_found}
    end
  end

  @spec gc(String.t(), pos_integer()) ::
          {:ok, map() | :noop} | {:error, :legacy_session | :not_found | term()}
  def gc(session_id, keep), do: GenServer.call(__MODULE__, {:gc, session_id, max(keep, 1)})

  @spec get_digest(String.t()) :: {:ok, map()} | {:error, :none}
  def get_digest(session_id), do: GenServer.call(__MODULE__, {:get_digest, session_id})

  @spec reconstruct(String.t(), (term(), Event.t() -> term()), term()) ::
          {:ok, term()} | {:error, :session_not_found | :session_ended}
  def reconstruct(session_id, reducer, initial),
    do: GenServer.call(__MODULE__, {:reconstruct, session_id, reducer, initial})

  @spec reconstruct_at(String.t(), String.t(), (term(), Event.t() -> term()), term()) ::
          {:ok, term()} | {:error, :session_not_found | :session_ended | :event_not_found | :pruned}
  def reconstruct_at(session_id, event_id, reducer, initial),
    do: GenServer.call(__MODULE__, {:reconstruct_at, session_id, event_id, reducer, initial})

  @doc """
  Session ids discoverable on disk (DETS backend) plus any loaded in memory.
  Used by `audit.recall` to search across sessions without a prior open.
  """
  @spec known_session_ids() :: [String.t()]
  def known_session_ids do
    on_disk =
      case File.ls(event_log_path()) do
        {:ok, files} ->
          for f <- files, String.ends_with?(f, ".dets"), do: Path.rootname(f)

        _ ->
          []
      end

    {:ok, loaded} = list_sessions()
    (on_disk ++ Enum.map(loaded, & &1.id)) |> Enum.uniq()
  end

  @doc """
  Flush and close every open session store.

  DETS buffers writes and only guarantees durability on close. A one-shot CLI
  command exits the VM as soon as `main/1` returns, which is BEFORE any
  terminate callback would run — so without this, events written moments
  earlier are still in the buffer and the file is left dirty. It then reopens
  as an empty, "not properly closed" table and the session reads as `LEGACY ·
  0`: the record silently vanishes.

  Long-running modes (the MCP server) do not need this — they keep the handle
  open for their whole life — but calling it is harmless there too.
  """
  @spec flush() :: :ok
  def flush, do: GenServer.call(__MODULE__, :flush)

  # ── Server callbacks ────────────────────────────────────────────────────────

  @impl true
  def init(_opts) do
    {:ok, %{sessions: %{}, store: select_store()}}
  end

  defp select_store do
    explicit = Application.get_env(:shem_spolia, :event_log_store)
    force_mnesia = Application.get_env(:shem_spolia, :force_mnesia, false)

    cond do
      explicit != nil -> explicit
      force_mnesia || Node.list() != [] -> ShemSpolia.EventLog.MnesiaStore
      true -> ShemSpolia.EventLog.DETSStore
    end
  end

  @impl true
  def handle_call(:start_session, _from, state) do
    session = Session.new()
    {:ok, handle} = state.store.open(session.id, event_log_path())
    sessions = Map.put(state.sessions, session.id, {handle, session})
    {:reply, {:ok, session.id}, %{state | sessions: sessions}}
  end

  @impl true
  def handle_call({:start_session, session_id}, _from, state) do
    case Map.fetch(state.sessions, session_id) do
      {:ok, _} ->
        {:reply, {:ok, session_id}, state}

      :error ->
        {:ok, handle} = state.store.open(session_id, event_log_path())
        {:ok, existing} = state.store.read_all(handle)

        pruned_count =
          case state.store.get_digest(handle) do
            {:ok, d} -> d.count
            _ -> 0
          end

        {last_hash, next_seq} =
          case List.last(existing) do
            nil ->
              {nil, pruned_count}

            last ->
              # seq counter must continue past PRUNED history too — length(existing)
              # alone would mint duplicate seqs after a GC. Trust the last stored seq.
              {last.hash, (last.seq || length(existing) - 1) + 1}
          end

        session = %Session{
          id: session_id,
          started_at: DateTime.utc_now(),
          last_hash: last_hash,
          event_count: next_seq,
          pruned_count: pruned_count
        }

        sessions = Map.put(state.sessions, session_id, {handle, session})
        {:reply, {:ok, session_id}, %{state | sessions: sessions}}
    end
  end

  @impl true
  def handle_call({:end_session, session_id}, _from, state) do
    case Map.fetch(state.sessions, session_id) do
      {:ok, {handle, session}} ->
        if handle, do: state.store.close(handle)
        closed = Session.close(session)
        sessions = Map.put(state.sessions, session_id, {nil, closed})
        {:reply, :ok, %{state | sessions: sessions}}

      :error ->
        {:reply, {:error, :session_not_found}, state}
    end
  end

  @impl true
  def handle_call({:finalize, session_id}, _from, state) do
    case Map.fetch(state.sessions, session_id) do
      {:ok, {handle, session}} ->
        closed = Session.close(session)
        sessions = Map.put(state.sessions, session_id, {handle, closed})
        {:reply, :ok, %{state | sessions: sessions}}

      :error ->
        {:reply, {:error, :session_not_found}, state}
    end
  end

  @impl true
  def handle_call({:reopen, session_id}, _from, state) do
    case Map.fetch(state.sessions, session_id) do
      {:ok, {handle, session}} ->
        sessions = Map.put(state.sessions, session_id, {handle, Session.reopen(session)})
        {:reply, :ok, %{state | sessions: sessions}}

      :error ->
        {:reply, {:error, :session_not_found}, state}
    end
  end

  @impl true
  def handle_call(:flush, _from, state) do
    sessions =
      Map.new(state.sessions, fn
        {id, {handle, session}} when handle != nil ->
          state.store.close(handle)
          {id, {nil, ShemSpolia.EventLog.Session.close(session)}}

        {id, entry} ->
          {id, entry}
      end)

    {:reply, :ok, %{state | sessions: sessions}}
  end

  @impl true
  def handle_call(:list_sessions, _from, state) do
    sessions = state.sessions |> Map.values() |> Enum.map(fn {_h, s} -> s end)
    {:reply, {:ok, sessions}, state}
  end

  @impl true
  def handle_call({:append, session_id, type, payload, parent_id}, _from, state) do
    case Map.fetch(state.sessions, session_id) do
      {:ok, {handle, session}} when handle != nil ->
        # A finalized session keeps its handle open but rejects appends.
        if is_nil(session.ended_at) do
          event = Event.new(session_id, type, payload, parent_id)
          prev = session.last_hash || Chain.genesis(session_id)
          # seq = this event's 0-based append index (monotonic per session) so the
          # store can read events back in append order, not timestamp order.
          event = %{event | hash: Chain.next(prev, event), seq: session.event_count}

          case state.store.append(handle, event) do
            :ok ->
              updated = %{Session.increment(session) | last_hash: event.hash}
              {updated, handle} = maybe_auto_gc(state, session_id, handle, updated)
              sessions = Map.put(state.sessions, session_id, {handle, updated})
              {:reply, {:ok, event}, %{state | sessions: sessions}}

            {:error, reason} ->
              {:reply, {:error, reason}, state}
          end
        else
          {:reply, {:error, :session_ended}, state}
        end

      {:ok, {nil, _session}} ->
        {:reply, {:error, :session_ended}, state}

      :error ->
        {:reply, {:error, :session_not_found}, state}
    end
  end

  @impl true
  def handle_call({:events, session_id}, _from, state) do
    case get_active_handle(state, session_id) do
      {:ok, handle} -> {:reply, state.store.read_all(handle), state}
      error -> {:reply, error, state}
    end
  end

  @impl true
  def handle_call({:read_session_events, session_id}, _from, state) do
    case Map.fetch(state.sessions, session_id) do
      {:ok, {handle, _}} when handle != nil ->
        {:reply, state.store.read_all(handle), state}

      _ ->
        # Session not in active state — try current store first (handles Mnesia
        # cross-node reads), then fall back to the DETS file on disk.
        case try_store_read(state.store, session_id) do
          {:ok, [_ | _]} = result -> {:reply, result, state}
          _ -> {:reply, read_dets_file(session_id), state}
        end
    end
  end

  @impl true
  def handle_call({:scrub, session_id, after_event_id}, _from, state) do
    case get_active_handle(state, session_id) do
      {:ok, handle} ->
        reply =
          case state.store.scrub(handle, after_event_id) do
            {:error, :event_not_found} -> missing_kind(state.store, handle, :event_not_found)
            other -> other
          end

        {:reply, reply, state}

      error ->
        {:reply, error, state}
    end
  end

  @impl true
  def handle_call({:event, session_id, event_id}, _from, state) do
    case get_active_handle(state, session_id) do
      {:ok, handle} ->
        reply =
          case state.store.get(handle, event_id) do
            {:error, :not_found} -> missing_kind(state.store, handle, :not_found)
            other -> other
          end

        {:reply, reply, state}

      error ->
        {:reply, error, state}
    end
  end

  @impl true
  def handle_call({:reconstruct, session_id, reducer, initial}, _from, state) do
    case get_active_handle(state, session_id) do
      {:ok, handle} ->
        {:ok, events} = state.store.read_all(handle)
        {:reply, {:ok, ShemSpolia.EventLog.Replay.fold(events, initial, reducer)}, state}

      error ->
        {:reply, error, state}
    end
  end

  @impl true
  def handle_call({:reconstruct_at, session_id, event_id, reducer, initial}, _from, state) do
    case get_active_handle(state, session_id) do
      {:ok, handle} ->
        {:ok, events} = state.store.read_all(handle)

        reply =
          case ShemSpolia.EventLog.Replay.state_at(events, event_id, initial, reducer) do
            {:error, :event_not_found} -> missing_kind(state.store, handle, :event_not_found)
            other -> other
          end

        {:reply, reply, state}

      error ->
        {:reply, error, state}
    end
  end

  @impl true
  def handle_call(:stats, _from, state) do
    total_events =
      state.sessions
      |> Map.values()
      |> Enum.map(fn {_h, s} -> s.event_count end)
      |> Enum.sum()

    {:reply, %{sessions: map_size(state.sessions), total_events: total_events}, state}
  end

  @impl true
  def handle_call({:gc, session_id, keep}, _from, state) do
    case Map.fetch(state.sessions, session_id) do
      {:ok, {handle, session}} when handle != nil ->
        case do_gc(state.store, handle, session_id, keep) do
          {:ok, %{total_pruned: total}} = ok ->
            sessions =
              Map.put(state.sessions, session_id, {handle, %{session | pruned_count: total}})

            {:reply, ok, %{state | sessions: sessions}}

          other ->
            {:reply, other, state}
        end

      _ ->
        # not active (never loaded, or ended): temp-open the store for the pass.
        # DETS creates a file on open, so require an existing one first.
        if store_has_session?(state.store, session_id) do
          {:ok, handle} = state.store.open(session_id, event_log_path())
          result = do_gc(state.store, handle, session_id, keep)
          state.store.close(handle)
          {:reply, result, state}
        else
          {:reply, {:error, :not_found}, state}
        end
    end
  end

  @impl true
  def handle_call({:get_digest, session_id}, _from, state) do
    case Map.fetch(state.sessions, session_id) do
      {:ok, {handle, _}} when handle != nil ->
        {:reply, state.store.get_digest(handle), state}

      _ ->
        if store_has_session?(state.store, session_id) do
          {:ok, handle} = state.store.open(session_id, event_log_path())
          result = state.store.get_digest(handle)
          state.store.close(handle)
          {:reply, result, state}
        else
          # store_has_session? missed (e.g. this node runs MnesiaStore but the
          # session's digest only lives in a .dets file) — mirror
          # read_session_events' fallback so a store mismatch doesn't
          # masquerade as "no digest" and send verify_chain walking from
          # genesis (false tamper alarm).
          {:reply, read_dets_digest(session_id), state}
        end
    end
  end

  # ── Helpers ─────────────────────────────────────────────────────────────────

  # an id missing from a GC'd session is indistinguishable from a pruned one —
  # report :pruned whenever a digest exists so callers get an honest signal.
  defp missing_kind(store, handle, miss) do
    case store.get_digest(handle) do
      {:ok, _} -> {:error, :pruned}
      _ -> {:error, miss}
    end
  end

  defp get_active_handle(state, session_id) do
    case Map.fetch(state.sessions, session_id) do
      {:ok, {handle, _session}} when handle != nil -> {:ok, handle}
      {:ok, {nil, _session}} -> {:error, :session_ended}
      :error -> {:error, :session_not_found}
    end
  end

  @doc """
  Where session logs live. `SHEM_SPOLIA_EVENT_LOG_PATH` wins, then app config,
  then the default under `~/.config`. The env var matters because the escript
  has no config file: it is the only way to point a running `shem_audit` at a
  different corpus.
  """
  def event_log_path do
    System.get_env("SHEM_SPOLIA_EVENT_LOG_PATH") ||
      Application.get_env(
        :shem_spolia,
        :event_log_path,
        Path.join([System.user_home!(), ".config", "shem_spolia", "events"])
      )
  end

  # MnesiaStore accepts session_id directly as a handle; DETSStore needs a table
  # handle and will error — that's the signal to fall through to the file read.
  defp try_store_read(store, session_id) do
    try do
      store.read_all(session_id)
    catch
      _, _ -> {:error, :not_found}
    end
  end

  # GC runs inline in this call — 2x hysteresis means once per keep_events
  # appends, and blocking the append is what makes digest-before-delete
  # trivially ordered.
  defp maybe_auto_gc(state, session_id, handle, session) do
    keep = Application.get_env(:shem_spolia, :gc, [])[:keep_events] || 100_000
    in_store = session.event_count - session.pruned_count

    if is_integer(keep) and in_store > 2 * keep do
      case do_gc(state.store, handle, session_id, keep) do
        {:ok, %{total_pruned: total}} -> {%{session | pruned_count: total}, handle}
        # :legacy_session or store errors: skip silently, disk keeps growing —
        # exactly the pre-GC status quo for that session.
        _ -> {session, handle}
      end
    else
      {session, handle}
    end
  end

  # The GC pass. Ordering is the crash-safety story: digest is durable BEFORE
  # any delete, so a crash leaves extra events (harmless — Chain.verify/3 skips
  # rows at or below the boundary), never a broken chain.
  defp do_gc(store, handle, session_id, keep) do
    keep = max(keep, 1)
    {:ok, raw_events} = store.read_all(handle)

    prior =
      case store.get_digest(handle) do
        {:ok, d} -> d
        _ -> nil
      end

    # Rows with seq <= prior.covers_to_seq can legitimately still be present
    # (a crash between put_digest and prune leaves them — Chain.verify already
    # skips them). Refilter so a re-run doesn't fold them into
    # portable_anchor/count a SECOND time.
    events =
      if prior do
        Enum.filter(raw_events, fn e -> (Map.get(e, :seq) || -1) > prior.covers_to_seq end)
      else
        raw_events
      end

    cond do
      # Map.get, not .seq — records stored before the :seq field exists can load
      # without the key.
      Enum.any?(raw_events, &is_nil(Map.get(&1, :seq))) ->
        {:error, :legacy_session}

      length(events) <= keep ->
        {:ok, :noop}

      true ->
        {pruned, kept} = Enum.split(events, length(events) - keep)

        seed = (prior && prior.portable_anchor) || ShemSpolia.Attest.portable_genesis(session_id)

        portable =
          Enum.reduce(pruned, seed, fn e, acc ->
            ShemSpolia.Attest.portable_next(
              acc,
              ShemSpolia.EventLog.CanonicalJSON.encode(ShemSpolia.Attest.event_view(e))
            )
          end)

        last = List.last(pruned)

        digest = %{
          covers_to_seq: last.seq,
          count: ((prior && prior.count) || 0) + length(pruned),
          beam_anchor: last.hash,
          portable_anchor: portable,
          pruned_at: DateTime.utc_now()
        }

        with :ok <- store.put_digest(handle, digest),
             :ok <- store.prune(handle, last.seq) do
          {:ok, %{pruned: length(pruned), total_pruned: digest.count, kept: length(kept)}}
        end
    end
  end

  # A session_id becomes a filesystem path (<events dir>/<id>.dets) on the
  # file fallbacks, and it arrives from remote surfaces (MCP arguments).
  # Anything outside [A-Za-z0-9_] is refused before the filesystem is touched —
  # traversal ids read as simply not found.
  defp path_safe_session_id?(session_id),
    do: is_binary(session_id) and session_id =~ ~r/^[A-Za-z0-9_]+$/

  defp store_has_session?(ShemSpolia.EventLog.DETSStore, session_id),
    do:
      path_safe_session_id?(session_id) and
        File.exists?(Path.join(event_log_path(), "#{session_id}.dets"))

  # Mnesia opens are non-creating lookups keyed by session id.
  defp store_has_session?(store, session_id) do
    case try_store_read(store, session_id) do
      {:ok, [_ | _]} -> true
      _ -> false
    end
  end

  defp read_dets_file(session_id) do
    dets_path = Path.join(event_log_path(), "#{session_id}.dets")

    if path_safe_session_id?(session_id) and File.exists?(dets_path) do
      table = :"spolia_history_#{session_id}_#{:erlang.unique_integer([:positive])}"

      case :dets.open_file(table, file: String.to_charlist(dets_path), type: :set) do
        {:ok, tab} ->
          # Sort by :seq (the hash chain's append order), matching
          # DETSStore.read_all — timestamp alone reorders same-microsecond
          # events and breaks chain verification.
          events =
            :dets.foldl(
              fn
                {_id, %Event{} = event}, acc -> [event | acc]
                _other, acc -> acc
              end,
              [],
              tab
            )
            |> Enum.sort_by(fn e ->
              {Map.get(e, :seq) || -1, DateTime.to_unix(e.timestamp, :microsecond)}
            end)

          :dets.close(tab)
          {:ok, events}

        {:error, _} ->
          {:error, :not_found}
      end
    else
      {:error, :not_found}
    end
  end

  # Same open/lookup/close pattern as read_dets_file/1, but for the reserved
  # :gc_digest row.
  defp read_dets_digest(session_id) do
    dets_path = Path.join(event_log_path(), "#{session_id}.dets")

    if path_safe_session_id?(session_id) and File.exists?(dets_path) do
      table = :"spolia_history_#{session_id}_#{:erlang.unique_integer([:positive])}"

      case :dets.open_file(table, file: String.to_charlist(dets_path), type: :set) do
        {:ok, tab} ->
          result =
            case :dets.lookup(tab, :gc_digest) do
              [{:gc_digest, digest}] -> {:ok, digest}
              _ -> {:error, :none}
            end

          :dets.close(tab)
          result

        {:error, _} ->
          {:error, :none}
      end
    else
      {:error, :none}
    end
  end
end
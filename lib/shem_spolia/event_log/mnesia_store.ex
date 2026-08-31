defmodule ShemSpolia.EventLog.MnesiaStore do
  @behaviour ShemSpolia.EventLog.Store

  require Logger

  @table :shem_spolia_events

  @doc """
  Creates the Mnesia schema (if absent) and the :shem_spolia_events table (if absent).
  Safe to call repeatedly — all operations are idempotent.
  """
  def setup! do
    Application.ensure_all_started(:mnesia)

    unless node() in :mnesia.table_info(:schema, :disc_copies) do
      # No disc schema on this node yet — create_schema requires Mnesia stopped.
      :mnesia.stop()
      :mnesia.create_schema([node()])
      Application.ensure_all_started(:mnesia)
    end

    case :mnesia.create_table(@table,
           attributes: [:key, :data],
           type: :ordered_set,
           disc_copies: [Node.self()]
         ) do
      {:atomic, :ok} ->
        :ok

      {:aborted, {:already_exists, @table}} ->
        :ok

      {:aborted, reason} ->
        raise "MnesiaStore: table creation failed: #{inspect(reason)}"
    end

    :mnesia.wait_for_tables([@table], 5_000)
    :ok
  end

  @doc """
  Adds a disc_copies replica of :shem_spolia_events on this node, pulling data from
  an existing cluster node. Called by ShemSpolia.Cluster on :nodeup.
  """
  def onboard_from(existing_node) do
    Application.ensure_all_started(:mnesia)

    case :mnesia.change_config(:extra_db_nodes, [existing_node]) do
      {:ok, _} ->
        :ok

      {:error, {:merge_schema_failed, reason}} ->
        # Our local disc schema conflicts with the cluster's schema (cookie mismatch).
        # Wipe our local schema and re-join — the cluster's data takes precedence.
        Logger.info("MnesiaStore: schema conflict with #{existing_node} (#{inspect(reason)}), re-joining cluster schema")
        :mnesia.stop()
        :mnesia.delete_schema([Node.self()])
        Application.ensure_all_started(:mnesia)

        case :mnesia.change_config(:extra_db_nodes, [existing_node]) do
          {:ok, _} -> :ok
          error -> raise "MnesiaStore: failed to join cluster schema after reset: #{inspect(error)}"
        end

      error ->
        raise "MnesiaStore: change_config failed: #{inspect(error)}"
    end

    case :mnesia.add_table_copy(@table, Node.self(), :disc_copies) do
      {:atomic, :ok} ->
        :ok

      {:aborted, {:already_exists, @table, _node}} ->
        :ok

      {:aborted, reason} ->
        raise "MnesiaStore: add_table_copy failed: #{inspect(reason)}"
    end

    :mnesia.wait_for_tables([@table], 10_000)
    :ok
  end

  # ── Store behaviour ──────────────────────────────────────────────────────────

  @impl true
  def open(session_id, _path), do: {:ok, session_id}

  @impl true
  def append(session_id, event) do
    :mnesia.dirty_write({@table, {session_id, event.id}, event})
  end

  @impl true
  def read_all(session_id) do
    match_head = {@table, {session_id, :_}, :"$1"}

    events =
      :mnesia.dirty_select(@table, [{match_head, [], [:"$1"]}])
      # the {session_id, :gc_digest} row matches the select too — events only
      |> Enum.filter(&is_struct(&1, ShemSpolia.EventLog.Event))
      |> Enum.sort_by(fn e -> {Map.get(e, :seq) || -1, DateTime.to_unix(e.timestamp, :microsecond)} end)

    {:ok, events}
  end

  @impl true
  def get(session_id, event_id) do
    case :mnesia.dirty_read(@table, {session_id, event_id}) do
      [{@table, _key, event}] -> {:ok, event}
      [] -> {:error, :not_found}
    end
  end

  @impl true
  def scrub(session_id, after_event_id) do
    {:ok, events} = read_all(session_id)

    case Enum.find_index(events, &(&1.id == after_event_id)) do
      nil ->
        {:error, :event_not_found}

      cut_index ->
        events
        |> Enum.drop(cut_index + 1)
        |> Enum.each(fn event ->
          :mnesia.dirty_delete(@table, {session_id, event.id})
        end)

        :ok
    end
  end

  @impl true
  def close(_session_id), do: :ok

  @impl true
  def prune(session_id, up_to_seq) do
    {:ok, events} = read_all(session_id)

    events
    |> Enum.filter(fn e -> (Map.get(e, :seq) || -1) <= up_to_seq end)
    |> Enum.each(fn e -> :mnesia.dirty_delete(@table, {session_id, e.id}) end)

    :ok
  end

  @impl true
  def get_digest(session_id) do
    case :mnesia.dirty_read(@table, {session_id, :gc_digest}) do
      [{@table, _key, digest}] -> {:ok, digest}
      [] -> {:error, :none}
    end
  end

  @impl true
  def put_digest(session_id, digest) do
    :mnesia.dirty_write({@table, {session_id, :gc_digest}, digest})
  end
end
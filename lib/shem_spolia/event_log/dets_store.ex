defmodule ShemSpolia.EventLog.DETSStore do
  @behaviour ShemSpolia.EventLog.Store

  @impl true
  def open(session_id, path) do
    File.mkdir_p!(path)
    file = Path.join(path, "#{session_id}.dets") |> String.to_charlist()
    table_name = :"shem_events_#{session_id}"

    case :dets.open_file(table_name, file: file, type: :set) do
      {:ok, table} -> {:ok, table}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def append(table, event) do
    case :dets.insert(table, {event.id, event}) do
      :ok -> :ok
      error -> error
    end
  end

  @impl true
  def read_all(table) do
    # Skip the reserved :gc_digest row — only Event structs are events.
    # DETS :set has no insertion order, so sort by the per-event append index
    # (:seq) — the hash chain's true order. Legacy events (no :seq) fall back to
    # timestamp. Map.get keeps pre-:seq records from raising on the missing key.
    events =
      :dets.foldl(
        fn
          {_id, %ShemSpolia.EventLog.Event{} = event}, acc -> [event | acc]
          _other, acc -> acc
        end,
        [],
        table
      )
      |> Enum.sort_by(fn e -> {Map.get(e, :seq) || -1, DateTime.to_unix(e.timestamp, :microsecond)} end)
    {:ok, events}
  end

  @impl true
  def get(table, event_id) do
    case :dets.lookup(table, event_id) do
      [{^event_id, event}] -> {:ok, event}
      [] -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def scrub(table, after_event_id) do
    {:ok, events} = read_all(table)

    case Enum.find_index(events, &(&1.id == after_event_id)) do
      nil ->
        {:error, :event_not_found}

      cut_index ->
        events
        |> Enum.drop(cut_index + 1)
        |> Enum.each(fn event -> :dets.delete(table, event.id) end)

        :ok
    end
  end

  @impl true
  def close(table) do
    :dets.close(table)
    :ok
  end

  @impl true
  def prune(table, up_to_seq) do
    {:ok, events} = read_all(table)
    events
    |> Enum.filter(fn e -> (Map.get(e, :seq) || -1) <= up_to_seq end)
    |> Enum.each(fn e -> :dets.delete(table, e.id) end)
    # make the deletes + digest durable now, not at close (GC is rare; crash-safety wins)
    :dets.sync(table)
    :ok
  end

  @impl true
  def get_digest(table) do
    case :dets.lookup(table, :gc_digest) do
      [{:gc_digest, digest}] -> {:ok, digest}
      _ -> {:error, :none}
    end
  end

  @impl true
  def put_digest(table, digest) do
    :ok = :dets.insert(table, {:gc_digest, digest})
    :dets.sync(table)
    :ok
  end
end
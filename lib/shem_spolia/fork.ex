defmodule ShemSpolia.Fork do
  @moduledoc """
  Counterfactual branch: copy a session's history up to a chosen event, then
  append an alternative turn in place of what actually happened.

  The branch is a REAL session with its own chain, genesis-anchored at its own
  id — so it verifies and attests exactly like any other session, and a bundle
  exported from it is indistinguishable in kind from a bundle of live history.
  What marks it as a branch is its first event, `:fork_created`, which records
  the parent session, the fork point, and the parent's head at fork time.

  Copied events are re-appended, so they get NEW ids and NEW hashes. The
  branch does not claim to be the parent; it claims to descend from it, and
  `:fork_created` carries the parent's `beam_head` so the claim is checkable.
  """

  alias ShemSpolia.EventLog

  @spec create(String.t(), String.t() | nil, map()) ::
          {:ok, %{fork_session_id: String.t(), fork_point: String.t() | nil, copied: non_neg_integer()}}
          | {:error, term()}
  def create(session_id, fork_point, alt_payload) when is_map(alt_payload) do
    with {:ok, _kind, _n} <- verified(session_id),
         {:ok, events} <- EventLog.read_session_events(session_id),
         {:ok, prefix, point_id} <- prefix_through(events, fork_point) do
      fork_id = "ses_fork_" <> Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)
      {:ok, ^fork_id} = EventLog.start_session(fork_id)

      {:ok, _} =
        EventLog.append(fork_id, :fork_created, %{
          parent_session: session_id,
          fork_point: point_id,
          parent_head: events |> List.last() |> then(& &1 && &1.hash),
          created_at: DateTime.utc_now() |> DateTime.to_iso8601()
        })

      Enum.each(prefix, fn e ->
        {:ok, _} = EventLog.append(fork_id, e.type, e.payload)
      end)

      {:ok, _} = EventLog.append(fork_id, :counterfactual_turn, alt_payload)

      :ok = EventLog.finalize(fork_id)

      {:ok, %{fork_session_id: fork_id, fork_point: point_id, copied: length(prefix)}}
    end
  end

  def create(_, _, _), do: {:error, :alt_response_must_be_an_object}

  defp verified(session_id) do
    case EventLog.verify_chain(session_id) do
      {:ok, kind, n} -> {:ok, kind, n}
      {:error, :not_found} -> {:error, :not_found}
      {:error, broken} -> {:error, {:chain_broken, broken}}
    end
  end

  # nil fork point = branch from the very end (the whole history is the prefix).
  defp prefix_through(events, nil), do: {:ok, events, events |> List.last() |> then(& &1 && &1.id)}

  defp prefix_through(events, event_id) do
    case Enum.find_index(events, &(&1.id == event_id)) do
      nil -> {:error, {:event_not_found, event_id}}
      idx -> {:ok, Enum.take(events, idx + 1), event_id}
    end
  end
end
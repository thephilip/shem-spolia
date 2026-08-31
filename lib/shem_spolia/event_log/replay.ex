defmodule ShemSpolia.EventLog.Replay do
  alias ShemSpolia.EventLog.Event

  @spec fold([Event.t()], state, (state, Event.t() -> state)) :: state when state: term()
  def fold(events, initial, reducer) do
    Enum.reduce(events, initial, fn event, acc -> reducer.(acc, event) end)
  end

  @spec state_at([Event.t()], String.t(), state, (state, Event.t() -> state)) ::
          {:ok, state} | {:error, :event_not_found}
        when state: term()
  def state_at(events, event_id, initial, reducer) do
    case Enum.find(events, &(&1.id == event_id)) do
      nil ->
        {:error, :event_not_found}

      _ ->
        state =
          Enum.reduce_while(events, initial, fn event, acc ->
            new_acc = reducer.(acc, event)
            if event.id == event_id, do: {:halt, new_acc}, else: {:cont, new_acc}
          end)

        {:ok, state}
    end
  end

  @spec causal_chain([Event.t()], String.t()) :: [Event.t()]
  def causal_chain(events, event_id) do
    index = Map.new(events, &{&1.id, &1})
    build_chain(index, event_id, [])
  end

  defp build_chain(_index, nil, acc), do: acc

  defp build_chain(index, event_id, acc) do
    case Map.fetch(index, event_id) do
      {:ok, event} -> build_chain(index, event.parent_id, [event | acc])
      :error -> acc
    end
  end
end
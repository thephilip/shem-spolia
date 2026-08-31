defmodule ShemSpolia.EventLog.Store do
  @moduledoc """
  Behaviour for event log storage backends.

  A `handle` is whatever `open/2` returns and every other callback accepts:
  a DETS table for `DETSStore`, the session id itself for `MnesiaStore`.
  """

  alias ShemSpolia.EventLog.Event

  @type handle :: term()

  @callback open(session_id :: String.t(), path :: String.t()) ::
              {:ok, handle()} | {:error, term()}
  @callback append(handle(), Event.t()) :: :ok | {:error, term()}
  @callback read_all(handle()) :: {:ok, [Event.t()]}
  @callback get(handle(), event_id :: String.t()) ::
              {:ok, Event.t()} | {:error, :not_found | term()}
  @callback scrub(handle(), after_event_id :: String.t()) :: :ok | {:error, :event_not_found}
  @callback close(handle()) :: :ok
  @callback prune(handle(), up_to_seq :: non_neg_integer()) :: :ok
  @callback get_digest(handle()) :: {:ok, map()} | {:error, :none}
  @callback put_digest(handle(), digest :: map()) :: :ok
end
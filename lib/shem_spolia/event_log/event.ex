defmodule ShemSpolia.EventLog.Event do
  @enforce_keys [:id, :session_id, :type, :payload, :timestamp]
  # `:seq` is a per-session monotonic append index used ONLY to read events back
  # in append order (the hash chain's order). It is deliberately NOT part of the
  # chained `canonical/1` in Chain, so it never affects integrity hashes. Nil on
  # events stored before this field existed — always read it via Map.get/2.
  defstruct [:id, :session_id, :parent_id, :type, :payload, :timestamp, :hash, :seq]

  @type t :: %__MODULE__{
          id: String.t(),
          session_id: String.t(),
          parent_id: String.t() | nil,
          type: atom(),
          payload: map(),
          timestamp: DateTime.t(),
          hash: String.t() | nil,
          seq: non_neg_integer() | nil
        }

  @spec new(String.t(), atom(), map(), String.t() | nil) :: t()
  def new(session_id, type, payload, parent_id \\ nil) do
    %__MODULE__{
      id: generate_id(),
      session_id: session_id,
      parent_id: parent_id,
      type: type,
      payload: payload,
      timestamp: DateTime.utc_now()
    }
  end

  @spec generate_id() :: String.t()
  def generate_id, do: "evt_" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
end
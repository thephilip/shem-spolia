defmodule ShemSpolia.EventLog.Session do
  @enforce_keys [:id, :started_at]
  defstruct [:id, :started_at, :ended_at, :last_hash, event_count: 0, pruned_count: 0]

  @type t :: %__MODULE__{
          id: String.t(),
          started_at: DateTime.t(),
          ended_at: DateTime.t() | nil,
          last_hash: String.t() | nil,
          event_count: non_neg_integer(),
          pruned_count: non_neg_integer()
        }

  @spec new() :: t()
  def new do
    %__MODULE__{
      id: generate_id(),
      started_at: DateTime.utc_now()
    }
  end

  @spec generate_id() :: String.t()
  def generate_id, do: "ses_" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)

  @spec increment(t()) :: t()
  def increment(%__MODULE__{} = session),
    do: %{session | event_count: session.event_count + 1}

  @spec close(t()) :: t()
  def close(%__MODULE__{} = session),
    do: %{session | ended_at: DateTime.utc_now()}

  @spec reopen(t()) :: t()
  def reopen(%__MODULE__{} = session),
    do: %{session | ended_at: nil}
end
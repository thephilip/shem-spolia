defmodule ShemSpolia.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    if Application.get_env(:shem_spolia, :force_mnesia, false) do
      ShemSpolia.EventLog.MnesiaStore.setup!()
    end

    children = [
      ShemSpolia.EventLog,
      ShemSpolia.Recall.Index
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: ShemSpolia.Supervisor)
  end
end
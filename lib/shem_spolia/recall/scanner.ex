defmodule ShemSpolia.Recall.Scanner do
  @moduledoc """
  Corpus enumeration for Recall: session DETS files under the configured
  `event_log_path`, read via `ShemSpolia.EventLog.read_session_events/1` —
  never a direct DETS open (DETS has no OS locking).
  """

  # Meta-sessions are instruments, not memories — never part of the corpus.
  @meta_sessions ["ses_RECALL_QUERIES", "ses_TOOL_INVOCATIONS"]

  @spec meta_sessions() :: [String.t()]
  def meta_sessions, do: @meta_sessions

  @spec sessions() :: [%{session_id: String.t(), cache_key: {integer(), integer()}}]
  def sessions do
    path = ShemSpolia.EventLog.event_log_path()

    case File.ls(path) do
      {:ok, files} ->
        files
        |> Enum.filter(&String.ends_with?(&1, ".dets"))
        |> Enum.map(&String.replace_suffix(&1, ".dets", ""))
        |> Enum.reject(&(&1 in @meta_sessions))
        |> Enum.flat_map(fn session_id ->
          case File.stat(Path.join(path, "#{session_id}.dets"), time: :posix) do
            {:ok, %File.Stat{mtime: mtime, size: size}} ->
              [%{session_id: session_id, cache_key: {mtime, size}}]

            {:error, _} ->
              []
          end
        end)

      {:error, _} ->
        []
    end
  end

  @spec events(String.t()) :: {:ok, [ShemSpolia.EventLog.Event.t()]} | {:error, term()}
  def events(session_id), do: ShemSpolia.EventLog.read_session_events(session_id)
end
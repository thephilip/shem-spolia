defmodule ShemSpolia.EventLog.Redact do
  @moduledoc """
  Replaces `{"$sensitive": value}` wrappers with `{"$redacted": sha256-16}`
  BEFORE the event is hashed, so the chain commits to the redacted form and
  verify/replay/attest stay intact. Strings are scanned too, because port-tool
  results arrive as JSON strings. Fail closed: a non-JSON string containing
  the marker is redacted whole.
  """

  @marker "$sensitive"

  def redact(%{@marker => v} = m) when map_size(m) == 1, do: marker(v)

  # structs (DateTime, custom) pass through — CanonicalJSON normalizes them at hash time
  def redact(%_{} = struct), do: struct

  def redact(%{} = m), do: Map.new(m, fn {k, v} -> {k, redact(v)} end)

  def redact(l) when is_list(l), do: Enum.map(l, &redact/1)

  def redact(s) when is_binary(s) do
    if String.contains?(s, "\"" <> @marker <> "\"") do
      case Jason.decode(s) do
        {:ok, decoded} -> Jason.encode!(redact(decoded))
        _ -> marker(s)
      end
    else
      s
    end
  end

  def redact(other), do: other

  defp marker(v) do
    encoded =
      try do
        Jason.encode!(v)
      rescue
        _ -> inspect(v)
      end

    h =
      :crypto.hash(:sha256, encoded)
      |> Base.encode16(case: :lower)
      |> binary_part(0, 16)

    %{"$redacted" => h}
  end
end
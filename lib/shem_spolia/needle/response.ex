defmodule ShemSpolia.Needle.Response do
  @moduledoc """
  One Needle turn, normalized.

  The shipped binary returns fields the published docs do not mention
  (`reason`, `validation`) and omits `validation` entirely on refusals — so
  this parses defensively against the ACTUAL wire format, verified against
  needle2 linux-x86_64, rather than the documented one.

  `type` is `"call"` when the model chose tools and `"respond"` when it is
  answering from results already in hand. A `"call"` with an empty
  `tool_calls` list is Needle's refusal: no declared tool serves the request.
  """

  @enforce_keys [:type, :tool_calls, :raw]
  defstruct [
    :type,
    :tool_calls,
    :reasoning,
    :confidence,
    :validation,
    :prefill_tps,
    :decode_tps,
    :peak_ram_mb,
    :raw,
    success: true,
    error: nil,
    error_code: nil
  ]

  @type tool_call :: %{name: String.t(), arguments: map()}

  @type t :: %__MODULE__{
          type: String.t(),
          tool_calls: [tool_call()],
          reasoning: String.t() | nil,
          confidence: float() | nil,
          validation: map() | nil,
          prefill_tps: float() | nil,
          decode_tps: float() | nil,
          peak_ram_mb: float() | nil,
          raw: map(),
          success: boolean(),
          error: String.t() | nil,
          error_code: String.t() | integer() | nil
        }

  @doc """
  Parse Needle's stdout. Tolerates leading/trailing noise by taking the last
  non-empty line, which is the JSON object.
  """
  @spec parse(binary()) :: {:ok, t()} | {:error, term()}
  def parse(output) when is_binary(output) do
    output
    |> String.split("\n", trim: true)
    |> List.last()
    |> case do
      nil ->
        {:error, {:empty_output, output}}

      line ->
        case Jason.decode(line) do
          {:ok, map} when is_map(map) -> {:ok, from_map(map)}
          {:ok, other} -> {:error, {:unexpected_json, other}}
          {:error, _} -> {:error, {:unparseable, String.slice(output, 0, 400)}}
        end
    end
  end

  @spec from_map(map()) :: t()
  def from_map(m) when is_map(m) do
    %__MODULE__{
      type: Map.get(m, "type", "unknown"),
      tool_calls: parse_calls(Map.get(m, "function_calls")),
      reasoning: Map.get(m, "reasoning"),
      confidence: Map.get(m, "confidence"),
      validation: Map.get(m, "validation"),
      prefill_tps: Map.get(m, "prefill_tps"),
      decode_tps: Map.get(m, "decode_tps"),
      peak_ram_mb: Map.get(m, "peak_ram_mb"),
      success: Map.get(m, "success", true),
      error: Map.get(m, "error"),
      error_code: Map.get(m, "error_code"),
      raw: m
    }
  end

  defp parse_calls(nil), do: []

  defp parse_calls(calls) when is_list(calls) do
    Enum.map(calls, fn c ->
      %{name: Map.get(c, "name"), arguments: Map.get(c, "arguments") || %{}}
    end)
  end

  defp parse_calls(_), do: []

  @doc """
  True when Needle declined: it produced no call because no declared tool
  serves the request. This is the documented contract for off-topic input,
  not an error.
  """
  @spec refusal?(t()) :: boolean()
  def refusal?(%__MODULE__{type: "call", tool_calls: []}), do: true
  def refusal?(%__MODULE__{}), do: false

  @doc """
  True when the model is answering from results rather than requesting a call.
  """
  @spec final?(t()) :: boolean()
  def final?(%__MODULE__{type: "respond"}), do: true
  def final?(%__MODULE__{}), do: false

  @doc """
  Whether the turn clears a confidence threshold.

  Needle's documented contract: act at or above your threshold, escalate below
  it. A turn with no confidence score does not clear any threshold.
  """
  @spec confident?(t(), float()) :: boolean()
  def confident?(%__MODULE__{confidence: c}, threshold) when is_number(c), do: c >= threshold
  def confident?(%__MODULE__{}, _threshold), do: false

  @doc """
  Argument names Needle flagged as ungrounded — present in the call but not
  evidenced by the input. Empty when the model raised nothing.
  """
  @spec ungrounded(t()) :: [String.t()]
  def ungrounded(%__MODULE__{validation: %{"ungrounded" => u}}) when is_list(u), do: u
  def ungrounded(%__MODULE__{}), do: []
end
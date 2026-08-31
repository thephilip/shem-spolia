defmodule ShemSpolia.Recall.Text do
  @moduledoc """
  Pure text machinery for Recall: payload flattening, tokenization, BM25.
  """

  @k1 1.2
  @b 0.75

  @spec flatten(term()) :: String.t()
  def flatten(nil), do: ""
  def flatten(s) when is_binary(s), do: s
  def flatten(%_{} = struct), do: to_string_safe(struct)
  def flatten(%{} = m), do: Enum.map_join(m, " ", fn {k, v} -> "#{flatten(k)} #{flatten(v)}" end)
  def flatten(l) when is_list(l), do: Enum.map_join(l, " ", &flatten/1)
  def flatten(t) when is_tuple(t), do: t |> Tuple.to_list() |> flatten()
  def flatten(other), do: to_string_safe(other)

  defp to_string_safe(v) do
    to_string(v)
  rescue
    _ -> inspect(v)
  end

  @spec tokenize(String.t()) :: [String.t()]
  def tokenize(s) do
    s
    |> String.downcase()
    |> String.split(~r/[^\p{L}\p{N}]+/u, trim: true)
    |> Enum.filter(&(String.length(&1) >= 2))
  end

  @doc "BM25 over tokenized docs. Descending score; zero-score docs omitted."
  @spec rank([String.t()], %{term() => [String.t()]}) :: [{term(), float()}]
  def rank([], _docs), do: []
  def rank(_q, docs) when map_size(docs) == 0, do: []

  def rank(query_tokens, docs) do
    n = map_size(docs)
    avgdl = docs |> Enum.map(fn {_, toks} -> length(toks) end) |> Enum.sum() |> Kernel./(n)

    # document frequency per query term
    df =
      Map.new(query_tokens, fn term ->
        {term, Enum.count(docs, fn {_, toks} -> term in toks end)}
      end)

    docs
    |> Enum.map(fn {id, toks} ->
      freqs = Enum.frequencies(toks)
      dl = length(toks)

      score =
        Enum.reduce(query_tokens, 0.0, fn term, acc ->
          tf = Map.get(freqs, term, 0)

          if tf == 0 do
            acc
          else
            idf = :math.log(1 + (n - df[term] + 0.5) / (df[term] + 0.5))
            acc + idf * (tf * (@k1 + 1)) / (tf + @k1 * (1 - @b + @b * dl / max(avgdl, 1.0e-9)))
          end
        end)

      {id, score}
    end)
    |> Enum.filter(fn {_, s} -> s > 0 end)
    |> Enum.sort_by(fn {_, s} -> -s end)
  end
end
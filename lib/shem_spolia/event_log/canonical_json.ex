defmodule ShemSpolia.EventLog.CanonicalJSON do
  @moduledoc """
  Deterministic JSON, byte-identical to Python
  `json.dumps(obj, sort_keys=True, separators=(",", ":"), ensure_ascii=False)`.

  Object key order is fixed by sorting; leaf strings/numbers/bools/null are
  delegated to `Jason.encode!/1`, whose escaping matches Python's (`"`, `\\`,
  control chars short-formed, non-ASCII left literal). Atoms become strings,
  tuples become arrays.

  ponytail: exotic floats (very large/small) may render differently than
  Python's `repr`; event payloads are strings/atoms/ints/maps in practice and
  the end-to-end verify covers real sessions. Add a float-normalization rule
  only if a real payload trips it.
  """

  @spec encode(term()) :: binary()
  def encode(term), do: term |> normalize() |> to_iodata() |> IO.iodata_to_binary()

  defp normalize(a) when is_atom(a) and a not in [nil, true, false], do: Atom.to_string(a)
  defp normalize(t) when is_tuple(t), do: t |> Tuple.to_list() |> Enum.map(&normalize/1)
  defp normalize(l) when is_list(l), do: Enum.map(l, &normalize/1)

  defp normalize(%mod{} = s) when mod in [DateTime, NaiveDateTime, Date, Time] do
    mod.to_iso8601(s)
  end

  defp normalize(%_{} = s), do: s |> Map.from_struct() |> normalize()

  defp normalize(m) when is_map(m) and not is_struct(m) do
    Map.new(m, fn {k, v} -> {to_string_key(k), normalize(v)} end)
  end

  defp normalize(other), do: other

  defp to_string_key(k) when is_binary(k), do: k
  defp to_string_key(k) when is_atom(k), do: Atom.to_string(k)
  defp to_string_key(k), do: to_string(k)

  defp to_iodata(m) when is_map(m) do
    body =
      m
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.map(fn {k, v} -> [Jason.encode!(k), ":", to_iodata(v)] end)
      |> Enum.intersperse(",")

    ["{", body, "}"]
  end

  defp to_iodata(l) when is_list(l) do
    ["[", l |> Enum.map(&to_iodata/1) |> Enum.intersperse(","), "]"]
  end

  defp to_iodata(scalar), do: Jason.encode!(scalar)
end
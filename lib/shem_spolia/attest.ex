defmodule ShemSpolia.Attest do
  @moduledoc """
  Export a recorded session as a self-verifying bundle.

  Read-only: never mutates the log, never halts.

  Two-head trust model:

    * `portable_head` — sha256 fold over the canonical-JSON lines in
      `events.jsonl`. `verify.py` recomputes this with Python stdlib alone.
    * `beam_head` — the live hash-chain head, which commits over Erlang term
      encoding rather than JSON. Not recomputable outside the BEAM; anyone
      running spolia can cross-check it against the source session.
  """

  alias ShemSpolia.EventLog
  alias ShemSpolia.EventLog.CanonicalJSON

  # Embedded at COMPILE time, not read from priv/ at runtime: an escript is a
  # single archive with no unpacked priv dir, so `:code.priv_dir/1` returns
  # {:error, :bad_name} there. These two files ARE the bundle's trust story —
  # they must ship inside the binary.
  @verify_py_path Path.join(__DIR__, "../../priv/attest/verify.py") |> Path.expand()
  @readme_path Path.join(__DIR__, "../../priv/attest/README.txt") |> Path.expand()
  @external_resource @verify_py_path
  @external_resource @readme_path
  @verify_py File.read!(@verify_py_path)
  @readme File.read!(@readme_path)

  @spec build(String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def build(session_id, opts \\ []) do
    out = Keyword.get(opts, :out, File.cwd!())

    with {:ok, _kind, _n} <- verify(session_id),
         {:ok, all_events} <- EventLog.read_session_events(session_id) do
      digest =
        case EventLog.get_digest(session_id) do
          {:ok, d} -> d
          _ -> nil
        end

      # Rows with seq <= digest.covers_to_seq can survive a crash between
      # put_digest and prune; they're already committed to by the digest
      # anchor, so exclude them here too — otherwise they'd be double-written
      # into events.jsonl and double-folded into the portable head on top of
      # the anchor that already covers them.
      events =
        if digest do
          Enum.filter(all_events, fn e -> (Map.get(e, :seq) || -1) > digest.covers_to_seq end)
        else
          all_events
        end

      lines = Enum.map(events, &CanonicalJSON.encode(event_view(&1)))
      seed = (digest && digest.portable_anchor) || portable_genesis(session_id)
      head = Enum.reduce(lines, seed, &portable_next(&2, &1))
      beam_head = events |> List.last() |> then(& &1 && &1.hash)
      tools = collect_tools(events)

      dir = Path.join(out, "attest-#{session_id}-#{String.slice(head, 0, 8)}")
      write_bundle(dir, session_id, events, lines, head, beam_head, tools, digest)
      {:ok, dir}
    end
  end

  defp verify(session_id) do
    case EventLog.verify_chain(session_id) do
      {:ok, kind, n} -> {:ok, kind, n}
      {:error, :not_found} -> {:error, :not_found}
      {:error, broken} -> {:error, {:chain_broken, broken}}
    end
  end

  # The exact fields Chain.canonical/1 commits to — no seq, no hash.
  @doc false
  def event_view(e) do
    %{
      id: e.id,
      session_id: e.session_id,
      type: e.type,
      payload: e.payload,
      timestamp: DateTime.to_iso8601(e.timestamp),
      parent_id: e.parent_id
    }
  end

  @spec portable_genesis(String.t()) :: String.t()
  def portable_genesis(session_id),
    do: :crypto.hash(:sha256, session_id) |> Base.encode16(case: :lower)

  @spec portable_next(String.t(), binary()) :: String.t()
  def portable_next(prev_hex, line),
    do: :crypto.hash(:sha256, prev_hex <> line) |> Base.encode16(case: :lower)

  # Events record the model-facing tool NAME (the manifest `name`), not an id.
  defp collect_tools(events) do
    events
    |> Enum.filter(&(&1.type == :agent_tool_called))
    |> Enum.map(&tool_name/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.map(&resolve_tool/1)
  end

  # payloads reach us with atom keys (in-process appends) or string keys
  # (decoded from JSON over MCP) — read both.
  defp tool_name(%{payload: p}) when is_map(p), do: p[:tool] || p["tool"]
  defp tool_name(_), do: nil

  defp resolve_tool(name) do
    case ShemSpolia.ToolSources.resolve(name) do
      {:ok, %{source: source, ext: ext, runtime: runtime}} ->
        sha = :crypto.hash(:sha256, source) |> Base.encode16(case: :lower)

        %{
          name: name,
          sha256: sha,
          runtime: runtime,
          ext: ext,
          source: source,
          status: "present"
        }

      :error ->
        %{name: name, sha256: nil, runtime: nil, ext: nil, source: nil, status: "missing"}
    end
  end

  defp write_bundle(dir, session_id, events, lines, head, beam_head, tools, digest) do
    File.rm_rf!(dir)
    File.mkdir_p!(Path.join(dir, "tools"))

    File.write!(Path.join(dir, "events.jsonl"), Enum.map(lines, &[&1, "\n"]))

    sha_lines =
      for t <- tools, t.status == "present" do
        file = "#{t.sha256}.#{t.ext}"
        File.write!(Path.join([dir, "tools", file]), t.source)
        "#{t.sha256}  tools/#{file}\n"
      end

    File.write!(Path.join(dir, "tools.sha256"), sha_lines)

    manifest = %{
      shem_spolia_version: Application.spec(:shem_spolia, :vsn) |> to_string(),
      session_id: session_id,
      event_count: length(events),
      exported_at: DateTime.utc_now() |> DateTime.to_iso8601(),
      genesis: portable_genesis(session_id),
      portable_head: head,
      beam_head: beam_head,
      tools: Enum.map(tools, &Map.take(&1, [:name, :sha256, :runtime, :status]))
    }

    manifest =
      if digest do
        Map.put(manifest, :gc, %{
          covers_to_seq: digest.covers_to_seq,
          pruned_count: digest.count,
          portable_anchor: digest.portable_anchor,
          beam_anchor: digest.beam_anchor,
          pruned_at: DateTime.to_iso8601(digest.pruned_at)
        })
      else
        manifest
      end

    File.write!(Path.join(dir, "manifest.json"), Jason.encode!(manifest, pretty: true))

    verify_path = Path.join(dir, "verify.py")
    File.write!(verify_path, @verify_py)
    File.chmod!(verify_path, 0o755)
    File.write!(Path.join(dir, "README.txt"), @readme)
  end
end
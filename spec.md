# Shem-spolia: Spec Draft (Option C)

**Working title:** *Shem-spolia — a portable, offline-verifiable auditor for local-model agents*

> **Spolia** (Latin, *spoliāre*): to strip the gear/armor from a fallen foe. The name signals the salvage — taking what works from Shem (the hash-chain, the attest bundles, the fork/replay/recall) and leaving the rest behind.

---

## Problem statement

Agents running on local models like Needle are increasingly common on laptops and single-board computers. Existing agent-audit solutions fall into two gaps:

1. **Commercial observability stacks** (LangSmith, etc.) require accounts, network egress, and trust the provider's runtime. Not usable offline or in airgapped environments.
2. **Emerging MCP auditor servers** (Tesserae, agent-audit-trail, etc.) produce hash-chained logs, but no portable verifier and no fork/replay/recall primitives. You can prove what happened, but not demonstrate alternatives or search the history by meaning.

Shem-spolia occupies the overlap: an MCP server that audit-logs every agent turn and tool call into a **hash-chained event log**, then exports **portable attest bundles** that any machine can verify with a stdlib-only Python script — plus **fork/recall** primitives that no competitor ships. It can also act as the agent's local brain via a `needle://` transport, so the auditor and the audited can run on the same machine.

## Architecture

```
┌─────────────────────────────┐    ┌──────────────────────┐
│ Claude Code / OpenCode /    │    │                      │
│ Needle-driven local agents  │◄──►│  Shem-spolia MCP     │
│                             │    │  Auditor             │
└─────────────────────────────┘    │                      │
                                   │  EventLog (hash     │
┌──────────────────────┐           │  chain + GC)         │
│ Needle C++ binary    │◄──────────┤                      │
│ (local model, <=200$)│           │  Attest bundle       │
│                      │           │  writer              │
└──────────────────────┘           │                      │
                                   └─────────┬────────────┘
                                             │
                                    ┌────────┴────────┐
                                    │ events.jsonl    │
                                    │ manifest.json   │
                                    │ tools/<sha>.ex  │
                                    │ verify.py       │
                                    └─────────────────┘
```

### Components

1. **MCP Auditor Server** (`shem_audit` binary)
   - Spawns as a stdio-MCP server (compatible with Claude Code, OpenCode, Claude Desktop, etc.).
   - Registers tools: `audit.verify_chain`, `audit.export_bundle`, `audit.fork_here`, `audit.recall`.
   - Connects to a local `Shem.EventLog` GenServer backed by DETS (single-node) or Mnesia (clustered).
   - Every inbound LLM turn and tool call — including calls to *other* MCP servers — is appended to the hash chain as events (`:llm_call_started`, `:llm_call_completed`, `:agent_tool_called`, `:agent_tool_result`, `:tool_invoked`).
   - No network egress by default. Binds to `127.0.0.1` only.

2. **Needle Transport** (`needle://` brain transport)
   - `Shem.LLM.Middleware.NeedleTransport` — a new `@behaviour Shem.LLM.Middleware` implementation.
   - Uses `Port.open({:spawn_executable, needle_binary})` to spawn the Needle C++ binary directly; communicates over stdin/stdout (JSON-lines in, JSON-lines out).
   - Parses Needle's response JSON into `%Shem.LLM.Response{content, tool_calls, tokens_used, ...}` — same struct the existing Anthropic/Ollama transports produce.
   - Registered in `Shem.LLM.Router` as `:needle` with no API key, no `base_url`. Model resolution: `config :shem, :llm_routes, %{needle: {:needle, "<path-to-model>"}}`.
   - The EventLogger middleware records every Needle call identically to every other transport — model-agnostic logging via the existing `:llm_call_started` / `:llm_call_completed` events.

3. **EventLog + Chain** (extracted core)
   - `Shem.EventLog.Chain` — pure functions: `genesis/1`, `next/2`, `verify/3`. SHA-256 over canonical event bytes. GC into rollup digests that anchor the chain.
   - `Shem.EventLog.Redact` — redacts before hashing so sensitive values (`{:put, {"$sensitive", value}}`) never appear in the chain as plaintext.
   - `Shem.EventLog.CanonicalJSON` — deterministic JSON byte-identical to Python's `json.dumps(obj, sort_keys=True, separators=(",",":"), ensure_ascii=False)`.

4. **Attest bundle writer** (extracted core)
   - `Shem.Attest.build/2` — exports `events.jsonl` + `manifest.json` + `tools/<sha256>.<ext>` + `verify.py` + `README.txt`.
   - Two-head trust model: `portable_head` (verifiable by `verify.py` with no Elixir) + `beam_head` (cross-check with Shem if you want to verify against the live chain).
   - Runs via `rpc` against the live node (no halt) or boots ephemeral for stopped sessions.

5. **Verify tool** (`priv/attest/verify.py`)
   - Python 3 stdlib only. No Elixir dependency. Recomputes the SHA-256 fold over `events.jsonl` and compares to `manifest.json`'s `portable_head`. Verifies every tool source hash in `tools/`.
   - This is the artifact that travels to regulators/auditors/machines without Shem installed.

6. **Recall** (`lib/shem/recall/` — pure BEAM, zero new deps)
   - BM25 lexical search over events. `recall_search` + `recall_context` MCP tools.
   - Hits carry snippet + `event_id` + fork pointer (nearest `:llm_call_completed` at-or-before the match).
   - Chain-broken sessions are refused as memory by both tools (`recall_context` returns `chain_broken`).
   - Optional explore note: session narrator (tiny model reads the event stream, emits a chain `:summary` event). Not built; documented as a future direction.

## MCP tools exposed by the auditor

| Tool | Arguments | Returns | Purpose |
|---|---|---|---|
| `audit.verify_chain` | `session_id` | `{valid: true/false, broken_at: event_id \| null, total: N}` | Recompute the hash chain and report integrity locally. |
| `audit.export_bundle` | `session_id, out_dir?` | `{bundle_path: string}` | Write a portable attest bundle to disk. Agent can hand the path to the user. |
| `audit.fork_here` | `session_id, alt_response` | `{fork_session_id: string, fork_point: event_id}` | Inject an alternative assistant turn at the current point, create a counterfactual branch, return its session ID. |
| `audit.recall` | `query, limit? \| prefix?` | `{hits: [{snippet, event_id, fork_point}], session_id: string \| chain_broken: true}` | Semantic search over all hash-verified sessions. |

## UI story

**Not required for MVP.** The auditor runs as a background MCP server; agents interact with it via the MCP tools above. Proof lives in the bundle on disk + `verify.py`.

**But the primitive WebUI timeline has salvage value** as the "show don't tell" surface for bundles:

- `GET /api/sessions/:id/events` — feed events to the existing timeline renderer at `/timeline`
- `GET /api/sessions/:id/verify` — the verify badge rendering
- Fork in the browser → `audit.fork_here` → resume → watch divergence live
- The timeline UI (from `PRODUCT.md` / `DESIGN.md`) already renders scrub/fork/diverge with verify badges — keep it as an optional demo surface, not a core requirement.

**TUI is not worth salvaging.** The existing one was "basically garbage" per the author's prior assessment, and the browser timeline does everything a CLI interface could. Drop it.

## Competitive differentiation

| Property | Shem-spolia | Tesserae | agent-audit-trail | LangSmith local |
|---|---|---|---|---|
| Hash-chained, tamper-evident | ✅ | ✅ (Ed25519) | ✅ (SHA-256) | ❌ |
| Offline verifier with no runtime | ✅ (`verify.py`, stdlib Python) | ✅ (Python CLI) | ✅ (Node.js) | ❌ (SaaS) |
| Offline-verifiable bundle with tool sources | ✅ | ❌ (hashes only) | ❌ | ❌ |
| Fork + replay + counterfactual diff | ✅ | ❌ | ❌ | ❌ |
| Recall over events by meaning | ✅ (BM25) | ❌ | ❌ | ❌ (tracing only) |
| Runs the local model too | ✅ (`needle://` transport) | ❌ | ❌ | ❌ |
| Airgapped / no account | ✅ | ✅ | ✅ | ❌ |

The unique combination: **portable attest bundles with tool source provenance + fork/replay/recall, all verifiable offline with a single `python3 verify.py` command.**

## Implementation notes

- The MCP server surface already exists in `lib/shem/mcp/` (server.ex, router.ex). The auditor adds a thin layer that wraps EventLog appends + exposes `audit.*` tools via the router.
- The Needle transport is ~80 lines (modeled on `OllamaTransport`/`LlamaCppTransport` in `lib/shem/llm/middleware/`). The `@behaviour Shem.LLM.Middleware` callback is `call/3` + optional `stream/4`. Port management mirrors `Shem.Lab.PortPool` patterns (`Port.open`, line-mode JSON parsing).
- The attest + EventLog + Chain + CanonicalJSON cores are pure logic; they extract cleanly from the supervision tree. No TUI / WebUI / application supervision needed for the headless auditor.
- Segment-digest GC is already implemented in `Shem.EventLog.GC` — the bundle writer handles pruned sessions via the digest anchor in `manifest.json`.

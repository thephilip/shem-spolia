# shem-spolia

A portable, offline-verifiable auditor for local-model agents.

`shem_audit` is an MCP server. Point any MCP client at it — Claude Code, OpenCode,
Claude Desktop — and every tool call it mediates lands in a SHA-256 hash chain.
Export a session and you get a bundle that anyone can verify on a machine with
no Elixir, no Erlang, and no network:

```
python3 verify.py .
events 1-42 OK · portable head 91356d2e… matches
VERIFIED
```

Salvaged from [Shem](../shem). *Spolia*: the reused stone of an older building,
visible in the wall of the new one.

## Status

Phase 0 complete and exercised end to end. Working today:

- hash-chained event log (DETS or Mnesia), with redaction before hashing and
  segment-digest GC
- attest bundles + the stdlib-Python verifier, with tamper detection proven by test
- counterfactual forks that are themselves real, verifiable, attestable sessions
- BM25 recall across chain-verified sessions, each hit carrying a fork point
- MCP server over stdio exposing all four `audit.*` tools

Not built yet: the Needle transport (Phase 1) and the WebUI timeline (Phase 3).
See `implementation_plan.md`.

## Build

Requires Erlang/OTP 27 and Elixir 1.17.

```bash
mix deps.get
MIX_ENV=prod mix escript.build   # -> ./shem_audit (1.4 MB, needs only `escript`)
```

## Use

```bash
./shem_audit serve                   # MCP server on stdio
./shem_audit sessions                # list recorded sessions
./shem_audit verify <session_id>     # recompute the chain
./shem_audit attest <session_id>     # write a bundle
```

Register with an MCP client:

```bash
claude mcp add shem-audit /path/to/shem_audit serve
```

### Tools

| Tool | What it does |
|---|---|
| `audit.verify_chain` | Recompute a session's chain; report the first broken event if any. |
| `audit.export_bundle` | Write a portable attest bundle; returns the path and a verify command. |
| `audit.fork_here` | Branch a session at an event, substituting an alternative turn. |
| `audit.recall` | BM25 search across chain-verified sessions; hits carry snippets and fork points. |

### Configuration

`SHEM_SPOLIA_EVENT_LOG_PATH` — where session logs live. Defaults to
`~/.config/shem_spolia/events`. This is the only knob the escript reads from the
environment; everything else is app config.

To put tool *source* in bundles, configure a resolver (see
`ShemSpolia.ToolSources`). Without one, tools export as `status: "missing"` —
the bundle proves they were called and with what arguments, but cannot carry
source it never had access to.

## Two heads

Every bundle carries two chain heads, and they answer different questions.

**`portable_head`** folds SHA-256 over the canonical-JSON lines of
`events.jsonl`. `verify.py` recomputes it with the Python standard library
alone. This is what makes a bundle evidence rather than a claim: the verifier
is 60 lines, reads only files in the bundle, and trusts nothing about the
machine that produced it.

**`beam_head`** is the live chain head, committing over Erlang term encoding
rather than JSON. `verify.py` cannot recompute it and says so. Anyone running
`shem_audit verify` against the source system can confirm it matches.

Tamper with one byte of `events.jsonl` and the fold diverges at that line and
never recovers:

```
CHAIN MISMATCH: recomputed a3f21c9e… != manifest 91356d2e…
FAILED
```

## Testing

```bash
mix run test/smoke.exs      # in-VM: record, verify, attest, tamper, fork, recall
python3 test/mcp_smoke.py   # drives the built ./shem_audit over real stdio
```

The MCP suite is not redundant with the in-VM one: it caught a bug the in-VM
suite structurally could not (`:code.priv_dir/1` returns `{:error, :bad_name}`
inside an escript, so `verify.py` never reached the bundle). Run both.

## What it does not do

- **Does not drive agents.** It records them. A harness could be built on top of
  the fork/replay primitives; that is a different project.
- **Cannot bundle third-party MCP tool source.** Those tools live on another
  machine. Bundles name them and prove they were called; source requires a
  configured resolver.
- **Does not prove the tool source in a bundle is the source that ran.** The
  event log records tool names at call time; source is captured at export.
- **Mnesia-backed sessions are not indexed by recall yet.** The corpus is the
  on-disk DETS directory.

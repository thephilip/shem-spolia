# shem-spolia

A portable, offline-verifiable record of what a coding agent did.

Hook `shem_audit record` into Claude Code and every tool call it makes — `Bash`,
`Edit`, `Write`, and any MCP tool — lands in a SHA-256 hash chain. Export a
session and you get a bundle that anyone can verify on a machine with no Elixir,
no Erlang, and no network:

```
python3 verify.py .
events 1-42 OK · portable head 91356d2e… matches
VERIFIED
```

Salvaged from [Shem](../shem). *Spolia*: the reused stone of an older building,
visible in the wall of the new one.

## What this proves, and what it does not

The chain proves **nobody edited the record after the fact**. Change one byte of
a recorded command and the bundle stops verifying, at that line, permanently.

It does **not** prove the record is complete. The hook runs because a settings
file says so, and whoever runs the agent can edit that file. Someone can remove
the hook, work, and put it back; the surviving chain verifies perfectly, because
it is intact. This is a tamper-evident record *of what was recorded* — not proof
of everything that happened.

Every cooperative audit log has this property. Naming it is the difference
between evidence and a claim.

## Status

Phases 0 through 4 complete and exercised end to end. Working today:

- hash-chained event log (DETS or Mnesia), with redaction before hashing and
  segment-digest GC
- **`shem_audit record`** — ingest a client's tool calls from a hook; proven
  against a real Claude Code session
- attest bundles + the stdlib-Python verifier, with tamper detection proven by test
- counterfactual forks that are themselves real, verifiable, attestable sessions
- BM25 recall across chain-verified sessions, each hit carrying a fork point
- MCP server over stdio exposing all four `audit.*` tools
- **Needle transport** — one-shot and stateful-session modes, every turn recorded
  in the chain with its confidence score
- **WebUI** — `shem_audit web` serves a chain-of-custody timeline on loopback:
  verify, fork, issue bundles, search recall, live-tail the log

See `implementation_plan.md` for what each phase actually shipped.

## Build

Requires Erlang/OTP 27 and Elixir 1.17.

```bash
mix deps.get
MIX_ENV=prod mix escript.build   # -> ./shem_audit (1.6 MB, needs only `escript`)
```

Or download `shem_audit` from a [release](../../releases) — it is BEAM bytecode
behind a shebang, so one file runs on any architecture and libc with an Erlang
runtime.

## Use

```bash
./shem_audit serve                   # MCP server on stdio
./shem_audit record                  # ingest one tool call on stdin (see below)
./shem_audit web                     # WebUI on http://127.0.0.1:4180
./shem_audit sessions                # list recorded sessions
./shem_audit verify <session_id>     # recompute the chain
./shem_audit attest <session_id>     # write a bundle
./shem_audit needle tools.json "dim the living room to 30"
```

## Recording an agent

`shem_audit` is an MCP server, but that is not how it observes an agent — an MCP
server cannot see calls the client makes to *other* servers, and never sees
built-in tools like `Bash`, which is where the risk actually lives. The client
has to hand over the record. Claude Code's `PostToolUse` hook does exactly that,
for every tool.

`.claude/settings.json`:

```json
{
  "hooks": {
    "PostToolUse": [
      {
        "matcher": "",
        "hooks": [
          { "type": "command", "command": "shem_audit record --quiet" }
        ]
      }
    ]
  }
}
```

An empty `matcher` matches every tool. The hook payload arrives on stdin;
`record` derives a spolia session id from the client's own `session_id`, so one
agent session is one chain:

```bash
./shem_audit sessions
ses_b0c2dbb9f2fc784d

./shem_audit verify ses_b0c2dbb9f2fc784d
VERIFIED · 2 events
```

**It never fails the agent.** A hook that exits nonzero interrupts the session it
is recording, so malformed input, a missing session id, or an unwritable log is a
line on stderr and exit 0. The gap shows up as a missing event, which is the
honest failure mode. Only a mistake in the *arguments* — the kind you make once,
at setup — exits nonzero.

Oversized values (a `Read` of a large file) collapse to `{"$truncated": {sha256,
bytes, head}}`. The chain still commits to the exact bytes without storing them.

`--session ID` overrides the derived id; `--type T` overrides the event type.
Any JSON object works, so any harness that can pipe JSON is a producer —
Claude Code is the tested path, not the only one.


## WebUI

```bash
./shem_audit web --port 4180
```

A demo surface over the same primitives the MCP tools use. Sessions down the
left, the event chain as an exhibit sheet, and the actions an auditor actually
takes: re-verify, issue a bundle, fork at an event, search recall. It live-tails
via SSE, so a session being recorded in another terminal appears as it happens.

**It refuses in public.** On a session whose chain is broken, `issue bundle` and
`fork here` render struck-out and disabled, the red thread running down the
events is visibly cut at the failing hash, and recall lists the session as
excluded rather than quietly dropping it. The refusal is the product working, so
it is shown rather than hidden.

No build step and no dependencies: an HTTP/1.1 server over `:gen_tcp`
(~250 lines) and a Preact + htm front end vendored as one file. HTML, CSS, JS
and fonts are embedded in the binary at compile time — the same
`@external_resource` trick `verify.py` uses, because an escript has no unpacked
`priv/`. The `app.js` in this repo is byte-identical to the one the binary
serves; nothing is minified or bundled.

Binds `127.0.0.1` only and refuses to bind anything else — enforced in
`Web.Server.bind_address/1`, not documented and hoped for. The CSP is
`default-src 'self'` with no `'unsafe-inline'`, which is also why the font is
self-hosted: a CDN link would be the auditor phoning home on page load.

Design system: `DESIGN.md`.

## Needle

[Cactus Needle](https://cactuscompute.com/needle) is a 45M-parameter tool-calling
model in a single 14 MB binary — no runtime, no downloads, no network. It answers
one question: given these tools and this sentence, which call with which
arguments? Off-topic input returns the empty call rather than prose.

Install it (the binary has the model baked in):

```bash
mkdir -p ~/.local/share/needle && cd ~/.local/share/needle
curl -sLO https://huggingface.co/Cactus-Compute/needle2/resolve/main/linux-x86_64/needle
chmod +x needle
export NEEDLE_PATH=~/.local/share/needle/needle
```

Then:

```bash
./shem_audit needle tools.json "turn off the porch lights"
set_lights {"on":false,"room":"porch"}
confidence: 0.8912
recorded in: ses_7b4b0a0758285de8
```

That session is a real chained record — verify it, attest it, fork it like any
other. What lands in the chain is the tool calls, the model's reasoning, and its
**confidence score**: Needle's contract is to act above a threshold and escalate
below it, so the number is *why the agent proceeded* and belongs in the evidence.

Two modes:

- **one-shot** (`Needle.complete/2`) — spawns `needle --prompt` per turn.
  Stateless, ~350 ms, nothing to supervise.
- **session** (`Needle.Session`) — holds a `needle --serve` process. Feed a tool
  result back and the model continues from it; later bare queries resolve against
  earlier turns. That state lives in the OS process, so **one session per
  conversation** — sharing one would leak history between them.

`Needle.audited_complete/3` wraps either and writes the turn into a session's chain.

### One sharp edge

Needle can go **blind to a tool whose JSON object does not lead with `name`** —
it answers `[]` ("no tool available") with high confidence, indistinguishable
from a legitimate refusal. Measured across 16 permutations on needle2
linux-x86_64: all 8 with `name` first produced the call; the failures all had
`description` first. Nested key order never mattered.

Elixir maps have no insertion order, so `Jason.encode!/1` on a tool map is a
coin flip. Always build tool files with `ShemSpolia.Needle.encode_tools/1`,
which emits `name` first by construction. `test/needle_smoke.exs` asserts the
hazard still reproduces, so a future Needle release that fixes it will show up
as a failing test rather than silence.

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
python3 test/ingest_smoke.py # drives `shem_audit record` as a hook would
python3 test/mcp_smoke.py   # drives the built ./shem_audit over real stdio
python3 test/web_smoke.py   # drives the built ./shem_audit over real HTTP
python3 test/web_interact.py http://127.0.0.1:4180/
                            # drives the UI in a real Chromium over CDP
NEEDLE_PATH=~/.local/share/needle/needle mix run test/needle_smoke.exs
                            # drives the real Needle model (skips if absent)
```

The out-of-VM suites are not redundant with the in-VM one: they caught three
bugs it structurally could not — `:code.priv_dir/1` returning
`{:error, :bad_name}` inside an escript (so `verify.py` never reached the
bundle), DETS never being flushed on a one-shot command (so a recorded session
reopened as `LEGACY · 0`, silently losing the evidence), and `Chain.verify/3`
reporting an *empty* session as `legacy` — a false "unverifiable" mark on every
session between creation and its first append. Run all of them.

`test/shot.py` and `test/shot_verified.py` screenshot a running server for
visual review. Both are stdlib-only CDP clients — no playwright, no node.

## What it does not do

- **Does not prove the record is complete.** See "What this proves" above. A
  cooperative recorder cannot; the hook is removable by whoever runs the agent.
- **Does not drive agents.** It records them. A harness could be built on top of
  the fork/replay primitives; that is a different project.
- **Cannot bundle third-party MCP tool source.** Those tools live on another
  machine. Bundles name them and prove they were called; source requires a
  configured resolver.
- **Does not prove the tool source in a bundle is the source that ran.** The
  event log records tool names at call time; source is captured at export.
- **Mnesia-backed sessions are not indexed by recall yet.** The corpus is the
  on-disk DETS directory.

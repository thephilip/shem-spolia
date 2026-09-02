# Shem-spolia: Implementation Plan

> Companion to `spec.md`. Maps the spec to the existing Shem codebase with concrete tasks, file paths, and dependency order.

---

## Phase 0: Extract the core (headless auditor) — **DONE**

Built and exercised end to end. `MIX_ENV=prod mix escript.build` produces a
1.4 MB `shem_audit` that runs anywhere with `escript` on PATH.

**Toolchain:** Erlang 27.3.4.16 + Elixir 1.17.3, installed via
`mise use -g erlang@27 elixir@1.17`. Neither was on the machine; this is a
prerequisite, not an afterthought.

### What shipped

| Module | Source it came from | Notes |
|---|---|---|
| `ShemSpolia.EventLog` | `lib/shem/event_log.ex` | telemetry span dropped; `known_session_ids/0` added |
| `EventLog.Chain` | same | **lowercase hex** (see divergences) |
| `EventLog.{Event,Session,Redact,Replay,CanonicalJSON}` | same | verbatim but for module names |
| `EventLog.Store` + `DETSStore` + `MnesiaStore` | same | `Store` behaviour written fresh (Shem's was not in the tree) |
| `ShemSpolia.Attest` | `lib/shem/attest.ex` | registry lookup replaced by `ToolSources`; priv files embedded |
| `ShemSpolia.ToolSources` | new | pluggable resolver; **empty by default** |
| `ShemSpolia.Fork` | new (informed by Shem's counterfactual work) | branches are real chained sessions |
| `Recall.{Text,Scanner,Index}` | `lib/shem/recall/` | meta-session exclusion list inlined |
| `MCP.{Server,Router,Tool}` + 4 tools | new | JSON-RPC 2.0 over stdio |
| `ShemSpolia.{Application,CLI}` | new | supervises EventLog + Recall.Index |

### Divergences from Shem (deliberate)

1. **Lowercase hex everywhere.** Shem's `Chain` emits uppercase (`Base.encode16`
   default) while its `portable_head` is lowercase, so the two heads in a bundle
   read differently. Spolia is lowercase throughout. Consequence: **spolia chains
   are not byte-compatible with existing Shem chains.** Clean slate, so this is
   free; it would not be if we were adopting Shem's logs.

2. **No tool registry.** Shem resolved tool source via `Shem.Lab.Registry`.
   Spolia audits agents that own their own tools, so source resolution is a
   configured callback and the honest default is `status: "missing"`.

3. **priv files embedded at compile time.** `:code.priv_dir/1` returns
   `{:error, :bad_name}` inside an escript. `verify.py` and `README.txt` are
   `@external_resource` + `File.read!` at compile time so they ship in the binary.

4. **No telemetry.** Nothing consumes it in a headless auditor.

### Verified, not assumed

`mix run test/smoke.exs` — 26 checks: record → redact → verify → attest →
`verify.py` VERIFIED → tamper → `CHAIN MISMATCH` + nonzero exit → fork → fork
verifies and attests → recall → MCP router dispatch.

`python3 test/mcp_smoke.py` — 18 checks driving the built binary over real
stdio: initialize, tools/list, notification handling without desync, JSON-RPC
error codes, self-auditing invocation log, export + offline verify, fork, recall.

Two bugs the in-VM suite could not have caught, both found by the stdio suite:
- `:code.priv_dir/1` failing in the escript (bundles shipped without `verify.py`)
- no way to redirect the log path in a config-file-less escript
  (`SHEM_SPOLIA_EVENT_LOG_PATH` added)

One test bug: the first recall assertion expected hits from
`ses_TOOL_INVOCATIONS`, which is excluded from the corpus **by design**. The
code was right; the test was wrong.

---

## Phase 0 (original plan, for reference)

The goal: a minimal `mix escript.build` that produces a `shem_audit` binary — no WebUI, no TUI, no application supervision. Just the MCP server + EventLog + Attest + verify.py.

### 0.1 Identify the extractable core modules

| Module | Current path | Extract? | Notes |
|---|---|---|---|
| `Shem.EventLog` | `lib/shem/event_log.ex` | ✅ | GenServer + append/verify/reopen |
| `Shem.EventLog.Chain` | `lib/shem/event_log/chain.ex` | ✅ | Pure functions: genesis/next/verify |
| `Shem.EventLog.CanonicalJSON` | `lib/shem/attest/canonical_json.ex` | ✅ | Deterministic JSON |
| `Shem.EventLog.Redact` | `lib/shem/event_log/redact.ex` | ✅ | Redaction before hashing |
| `Shem.EventLog.GC` | `lib/shem/event_log/gc.ex` | ✅ | Segment-digest rollups |
| `Shem.Attest` | `lib/shem/attest.ex` | ✅ | Bundle writer + two-head model |
| `Shem.Attest.Verify` | `priv/attest/verify.py` | ✅ | Stdlib Python verifier |
| `Shem.MCP.Server` | `lib/shem/mcp/server.ex` | ✅ | stdio MCP server |
| `Shem.MCP.Router` | `lib/shem/mcp/router.ex` | ✅ | Tool dispatch |
| `Shem.LLM.Middleware` | `lib/shem/llm/middleware.ex` | ✅ | @behaviour + callbacks |
| `Shem.LLM.Response` | `lib/shem/llm/response.ex` | ✅ | Unified response struct |
| `Shem.Recall` | `lib/shem/recall/` | ✅ | BM25 search |
| `Shem.Lab.PortPool` | `lib/shem/lab/port_pool.ex` | ✅ | Port management pattern |
| `Shem.Lab.Executor` | `lib/shem/lab/executor.ex` | ✅ | Tool execution logging |
| `Shem.Lab.Registry` | `lib/shem/lab/registry.ex` | ⚠️ | Only for Shem-graduated tools |

**Dependencies to drop:** `shem_ui`, `shem_tui`, `phoenix`, `phoenix_live_view`, `phoenix_pubsub`, `phoenix_html`, `esbuild`, `tailwind`, `heroicons`.

### 0.2 Create a new mix project structure

```
shem-spolia/
├── mix.exs                    # New project: only :escript, :mnesia, :dets, :crypto, :logger, :jason, :req
├── lib/
│   ├── shem_spolia/           # New top-level module
│   │   ├── application.ex     # Minimal supervision tree
│   │   ├── mcp/               # MCP auditor server
│   │   │   ├── server.ex      # <- adapted from lib/shem/mcp/server.ex
│   │   │   ├── router.ex      # <- adapted from lib/shem/mcp/router.ex
│   │   │   └── tools/         # audit.* tools
│   │   │       ├── verify_chain.ex
│   │   │       ├── export_bundle.ex
│   │   │       ├── fork_here.ex
│   │   │       └── recall.ex
│   │   ├── event_log/         # Extracted core
│   │   │   ├── chain.ex
│   │   │   ├── canonical_json.ex
│   │   │   ├── redact.ex
│   │   │   └── gc.ex
│   │   ├── attest/            # Extracted core
│   │   │   └── verify.py      # Copied verbatim
│   │   └── llm/
│   │       ├── middleware.ex
│   │       └── response.ex
│   └── shem/                  # Thin adapter to keep existing code working
│       ├── event_log.ex       # Delegates to ShemSpolia.EventLog
│       ├── attest.ex          # Delegates to ShemSpolia.Attest
│       └── ...
├── priv/
│   └── attest/verify.py
└── apps/
    └── shem/                  # Keep for downstream compatibility (optional)
```

### 0.3 Tasks

- [ ] Create `shem-spolia/mix.exs` with minimal deps
- [ ] Copy `verify.py` to `priv/attest/verify.py`
- [ ] Extract `EventLog` + `Chain` + `CanonicalJSON` + `Redact` + `GC` → `lib/shem_spolia/event_log/`
- [ ] Extract `Attest` → `lib/shem_spolia/attest/`
- [ ] Extract `MCP.Server` + `MCP.Router` → `lib/shem_spolia/mcp/`
- [ ] Write four `audit.*` tool modules in `lib/shem_spolia/mcp/tools/`
- [ ] Write minimal `Application` that starts: EventLog GenServer + MCP stdio server
- [ ] Add `escript: [main_module: ShemSpolia.CLI]` to mix.exs
- [ ] Write `ShemSpolia.CLI` with `main/1` that boots the application and blocks

---

## Phase 1: Needle transport — **DONE**

Built against the real model, not the docs. `needle2` linux-x86_64, downloaded
from Hugging Face (public, Apache-2.0, **no token required** — the model page is
ungated despite the spec assuming otherwise).

### What shipped

| Module | Purpose |
|---|---|
| `ShemSpolia.Needle` | binary discovery, one-shot `complete/2`, `audited_complete/3`, `encode_tools/1` |
| `ShemSpolia.Needle.Response` | normalized turn: calls, confidence, validation, refusal/final predicates |
| `ShemSpolia.Needle.Session` | supervised `needle --serve` process, stateful multi-turn |
| `ShemSpolia.Needle.HTTP` | ~140-line HTTP/1.1 POST over `:gen_tcp` |
| `shem_audit needle` | CLI: one audited turn, prints calls + confidence + session id |

### Corrections to the spec, from measurement

1. **Not an HTTP-only transport, and not a `Port`-only one either.** Needle has
   *two* modes and they are not interchangeable: `--prompt` is stateless
   (Port, ~350 ms), `--serve` is a stateful HTTP conversation. The spec assumed
   one transport shape; the model needs both, and the difference is semantic
   (conversation memory), not mechanical.

2. **`--serve` holds conversation state in the OS process.** Verified: turn 3
   ("now the bedroom too") resolved against turn 1's kitchen. So a session owns
   its server exclusively — a shared pool would cross-contaminate histories.
   Each session takes an OS-assigned free port.

3. **The response schema differs from the published docs.** The shipped binary
   returns `reason` (undocumented) and `validation` (undocumented:
   `{ungrounded: [...], negation: bool}`), and omits `validation` entirely on
   refusals. `Response` parses defensively against the real wire format.

4. **`:httpc` is unusable here.** It constructs TLS defaults *before* inspecting
   the scheme, so a plain `http://127.0.0.1` POST raises
   `:public_key.pkix_verify_hostname_match_fun/1 is undefined` in a stripped
   escript. Writing the HTTP client directly costs ~140 lines and keeps the
   binary dependency-free.

5. **Tool JSON key order changes model behavior.** See below.

### The name-first hazard

A tool object that does not lead with `"name"` can be **invisible** to Needle:
it answers `[]` with high confidence, which is byte-identical to a legitimate
"no tool serves this" refusal. Silent wrong behavior, not an error.

Bisected across 16 permutations (deterministic — same bytes, same confidence):

| top-level order | result |
|---|---|
| `name` first (8 combinations) | CALL, every time |
| `description` first + apostrophe in description (4) | refusal, every time |
| `description` first, no apostrophe (4) | CALL |

Nested key order (`parameters`, `properties`) never mattered. The apostrophe
only matters once the ordering is already wrong.

Elixir maps do not preserve insertion order, so `Jason.encode!/1` on a tool map
emits whatever order the map iterates — a coin flip on this behavior.
`Needle.encode_tools/1` emits `name` first by construction, and
`test/needle_smoke.exs` keeps a live assertion that the hazard reproduces, so a
future Needle release fixing it surfaces as a failing test rather than silence.

### Two more bugs, found by running it

**1. One-shot CLI commands lost their evidence.** `shem_audit needle ...`
recorded a turn, then `verify` reported `LEGACY · 0` with "dets: file not
properly closed". **DETS only guarantees durability on close, and an escript
exits the moment `main/1` returns** — no terminate callback runs. Every
one-shot CLI command was affected.

Fixed with `EventLog.flush/0`, called from a single `one_shot/1` wrapper and
from `die/1` (since `System.halt/1` also skips `after` blocks). Now:
`VERIFIED · 2 events`, attests, passes `verify.py`.

**2. `Session.stop/1` leaked the OS process.** `Port.close/1` detaches the BEAM
from the pipe but leaves `needle --serve` running — 8 orphans accumulated
across one test run, each holding a TCP port and ~26 MB. Worse: each inherited
the VM's stdout, so a *finished* test suite piped to `tail` never saw EOF and
hung indefinitely. That symptom is what exposed it.

Fixed by signalling the OS pid directly (`Port.info/1` → `:os_pid`, TERM then
KILL) and by spawning with `:stderr_to_stdout` so needle's output stays on the
port we own. `test/needle_smoke.exs` now asserts via `ps` that no child
survives a stop.

Both are the class of bug the in-VM suite cannot catch: one needs process
exit, the other needs process *lifetime*.

### Verified

`NEEDLE_PATH=... mix run test/needle_smoke.exs` — 44 checks against the real
model: tool encoding, one-shot calls with argument extraction, refusal on
off-topic input, parallel calls, system facts, tools-as-file-path, the
name-first hazard reproducing, confidence gating, stateful multi-turn with
result feedback, session isolation on separate ports, **no orphaned OS
processes after stop**, audited turns entering the chain with confidence
recorded, offline attest verification, and failure recorded rather than
swallowed.

Skips cleanly (exit 0) when no Needle binary is present.

---

### 1.1 Design

- New module: `ShemSpolia.LLM.Middleware.NeedleTransport`
- Implements `@behaviour ShemSpolia.LLM.Middleware` (`call/3`, optional `stream/4`)
- Uses `Port.open({:spawn_executable, needle_path}, [:binary, :stderr_to_stdout, :exit_status])`
- Parses JSON lines from stdout → `%ShemSpolia.LLM.Response{}`
- Registered in `ShemSpolia.LLM.Router` (new module, mirrors `Shem.LLM.Router`) as `:needle`

### 1.2 File: `lib/shem_spolia/llm/middleware/needle_transport.ex`

```elixir
defmodule ShemSpolia.LLM.Middleware.NeedleTransport do
  @behaviour ShemSpolia.LLM.Middleware
  @moduledoc "Needle C++ binary transport — zero-config, local tool-calling model"

  @impl true
  def call(%{model: model, messages: messages, tools: tools, config: config}, _state, _opts) do
    needle_path = config[:needle_path] || System.get_env("NEEDLE_PATH") || "/usr/local/bin/needle"
    # Build prompt with tool definitions + conversation
    prompt = build_needle_prompt(messages, tools)
    # Spawn Port, send JSON, read JSON lines, parse into %Response{}
  end

  @impl true
  def stream(%{model: model, messages: messages, tools: tools, config: config}, _state, _opts) do
    # Needle supports streaming? If yes, yield chunks; if no, delegate to call/3
  end
end
```

### 1.3 Tasks

- [ ] Create `lib/shem_spolia/llm/middleware/needle_transport.ex`
- [ ] Create `lib/shem_spolia/llm/router.ex` with `@backend_modules [:needle, :anthropic, :openai, :ollama, :llama_cpp]`
- [ ] Add config: `config :shem_spolia, :llm_routes, %{needle: {:needle, "/path/to/needle"}}`
- [ ] Test with actual Needle binary (download from Hugging Face, make executable)

---

## Phase 2: MCP auditor tools (the four `audit.*` tools) — **DONE**

Shipped in the Phase 0 commit (8e04d3a), which is why this section was never
marked. All four tools live in `lib/shem_spolia/mcp/tools/` and are registered
in `ShemSpolia.MCP.Router`. `test/mcp_smoke.py` drives them over real stdio.

### 2.1 Tool: `audit.verify_chain`

```elixir
# lib/shem_spolia/mcp/tools/verify_chain.ex
defmodule ShemSpolia.MCP.Tools.VerifyChain do
  use ShemSpolia.MCP.Tool, name: "audit.verify_chain"

  @impl true
  def schema do
    %{
      type: "object",
      properties: %{
        session_id: %{type: "string"}
      },
      required: ["session_id"]
    }
  end

  @impl true
  def call(%{"session_id" => session_id}) do
    {:ok, log} = ShemSpolia.EventLog.open(session_id)
    result = ShemSpolia.EventLog.Chain.verify(log)
    {:ok, %{valid: result.valid, broken_at: result.broken_at, total: result.count}}
  end
end
```

### 2.2 Tool: `audit.export_bundle`

```elixir
# lib/shem_spolia/mcp/tools/export_bundle.ex
defmodule ShemSpolia.MCP.Tools.ExportBundle do
  use ShemSpolia.MCP.Tool, name: "audit.export_bundle"

  @impl true
  def schema do
    %{
      type: "object",
      properties: %{
        session_id: %{type: "string"},
        out_dir: %{type: "string"}
      },
      required: ["session_id"]
    }
  end

  @impl true
  def call(%{"session_id" => session_id, "out_dir" => out_dir \\ "."}) do
    {:ok, log} = ShemSpolia.EventLog.open(session_id)
    bundle_path = ShemSpolia.Attest.build(log, out_dir)
    {:ok, %{bundle_path: bundle_path}}
  end
end
```

### 2.3 Tool: `audit.fork_here`

```elixir
# lib/shem_spolia/mcp/tools/fork_here.ex
defmodule ShemSpolia.MCP.Tools.ForkHere do
  use ShemSpolia.MCP.Tool, name: "audit.fork_here"

  @impl true
  def schema do
    %{
      type: "object",
      properties: %{
        session_id: %{type: "string"},
        alt_response: %{type: "object"}  # Full assistant message to inject
      },
      required: ["session_id", "alt_response"]
    }
  end

  @impl true
  def call(%{"session_id" => session_id, "alt_response" => alt}) do
    {:ok, log} = ShemSpolia.EventLog.open(session_id)
    fork_id = ShemSpolia.EventLog.fork(log, alt)
    {:ok, %{fork_session_id: fork_id, fork_point: ...}}
  end
end
```

### 2.4 Tool: `audit.recall`

```elixir
# lib/shem_spolia/mcp/tools/recall.ex
defmodule ShemSpolia.MCP.Tools.Recall do
  use ShemSpolia.MCP.Tool, name: "audit.recall"

  @impl true
  def schema do
    %{
      type: "object",
      properties: %{
        query: %{type: "string"},
        limit: %{type: "integer", default: 10},
        session_id: %{type: "string"}  # Optional: search within one session
      },
      required: ["query"]
    }
  end

  @impl true
  def call(%{"query" => query, "limit" => limit, "session_id" => session_id}) do
    if session_id do
      {:ok, log} = ShemSpolia.EventLog.open(session_id)
      if ShemSpolia.EventLog.chain_valid?(log) do
        hits = ShemSpolia.Recall.search(log, query, limit)
        {:ok, %{hits: hits, session_id: session_id}}
      else
        {:ok, %{chain_broken: true}}
      end
    else
      # Search all sessions
      sessions = ShemSpolia.EventLog.all_sessions()
      hits = Enum.flat_map(sessions, fn log ->
        if ShemSpolia.EventLog.chain_valid?(log) do
          ShemSpolia.Recall.search(log, query, limit)
        else
          []
        end
      end)
      {:ok, %{hits: Enum.take(hits, limit)}}
    end
  end
end
```

### 2.5 Tasks

- [x] Implement four tool modules
- [x] Register them in `ShemSpolia.MCP.Router`
- [x] Verify MCP stdio server loads and exposes all four tools

---

## Phase 3: WebUI — **DONE**

Built as a demo surface with no new dependencies and no build step. `shem_audit
web` serves a chain-of-custody view on `127.0.0.1:4180`; the binary grew from
1.4 MB to 1.64 MB and still needs nothing but `escript` on PATH.

### What shipped

| Module | Purpose |
|---|---|
| `ShemSpolia.Web.Server` | HTTP/1.1 over `:gen_tcp` — parse, route, respond; loopback enforced at bind |
| `ShemSpolia.Web.Router` | 11 routes; wrong verb on a known path is 405, not 404 |
| `ShemSpolia.Web.API` | sessions, events, verify, attest, fork, recall, stats |
| `ShemSpolia.Web.Stream` | SSE live tail, polling on `{count, head_hash}` |
| `ShemSpolia.Web.Assets` | compile-time embedded HTML/CSS/JS/fonts + CSP |
| `priv/web/app.js` | Preact + htm UI, ~490 lines, no build step |
| `shem_audit web [--port N]` | CLI entry |

### Why not Bandit/Plug

The claim of this binary is one file, no toolchain. Bandit would not have broken
that — escripts bundle deps fine — but it couples an explicitly *optional* demo
to the shipping artifact's dependency set. The surface needed is small enough to
own: loopback only, single reader, GET static + a JSON API + one SSE stream.
`Needle.HTTP` had already proved the harder direction (client) in 140 lines.

Same reasoning on the front end. React needs node/npm/a bundler, which is the
toolchain the binary exists to avoid. **Preact + htm** (13 KB, vendored, one
file) gives the same component model and hooks with zero build step, so the
`app.js` in the repo is byte-identical to the one the binary serves — which
matters for a tool whose pitch is "check this yourself."

### Design: CUSTODY

Full system in `DESIGN.md`. The premise: **the output is an exhibit**, so the UI
is a chain-of-custody sheet, not a dashboard. Dark carbon stock, Courier Prime
throughout, red thread down the event chain that is **visibly severed** at a hash
mismatch. Disposition is typed onto a ruled line rather than stamped; refusals
render struck-out rather than hidden.

Fonts are self-hosted and embedded (SIL OFL, ~85 KB for three faces) because the
CSP is `default-src 'self'` and the tool claims no network egress — a font CDN
would be the auditor phoning home on page load.

### Divergences from the original Phase 3 plan

1. **No Phoenix, no LiveView, no `phoenix_pubsub`.** See above. The plan assumed
   adding them back; the binary is better without them.
2. **No `Shem.Lab.Registry`-style timeline reuse.** Shem's timeline LiveView
   renders *agents*; spolia's objects are chains, bundles, forks and recall
   hits. Adapting it would have meant carrying UI for concepts spolia does not
   have.
3. **SSE, not LiveView diffing.** The EventLog has no pub/sub, and adding a
   broadcast to the append path would make the recording hot path pay for a
   feature only the demo uses. Polling also catches writes from a *different*
   `shem_audit` process against the same log directory, which a broadcast
   would miss.

### One real bug, found by the smoke test

`Chain.verify/3` reported `{:ok, :legacy, 0}` for an **empty** session. `:legacy`
is a claim about evidence we cannot speak to — an unhashed prefix from before
chaining existed. A session with no events has no such prefix; it has nothing,
which is trivially intact. Every session created by `start_session/0` therefore
carried a false "unverifiable" mark until its first append, and the web UI
rendered that verdict prominently.

Fixed with an explicit `verify([], _, nil) -> {:ok, :verified, 0}` clause. In a
tool whose entire value is saying precisely what it does and does not know, a
false accusation is worse than a crash.

### Verified

`python3 test/web_smoke.py` — **59 checks** driving the built binary over real
HTTP: every static asset with its content type, woff2 magic bytes surviving the
escript archive, CSP/nosniff/traversal, the full JSON API, 404 vs 405 vs 422,
attest → `verify.py` VERIFIED → tamper the bundle → MISMATCH + nonzero exit,
fork descent recorded, SSE frames parsing, and `ss -ltnp` confirming the socket
is bound to `127.0.0.1` only.

`python3 test/web_interact.py` — **24 checks** driving a real Chromium over CDP:
session selection, payload expand/collapse, re-verify, bundle issue with the
missing-tool-source finding, fork modal rejecting bad JSON client-side, branch
creation switching selection, and recall showing the tampered session as
`excluded` while serving zero hits from it.

`test/shot.py` / `test/shot_verified.py` capture screenshots for visual review
(stdlib-only CDP client; no playwright/node).

---

## Phase 3 (original plan, for reference)

### 3.1 Scope decision

The spec treats WebUI as "optional demo surface." If kept:

- Add `phoenix`, `phoenix_live_view`, `phoenix_pubsub` back to deps
- Create a minimal Phoenix endpoint serving:
  - `GET /api/sessions/:id/events` → JSON array of events
  - `GET /api/sessions/:id/verify` → `{valid: true/false}`
  - `GET /timeline/:id` → LiveView timeline page
- Reuse existing timeline LiveView from `lib/shem_web/live/timeline_live.ex` (adapt to `ShemSpolia`)

### 3.2 Tasks (if WebUI in scope)

- [ ] Add Phoenix deps to mix.exs
- [ ] Create `lib/shem_spolia_web/endpoint.ex`
- [ ] Create `lib/shem_spolia_web/live/timeline_live.ex` (adapted from Shem)
- [ ] Add CSS using the oklch design system from `DESIGN.md`
- [ ] Add "Export Bundle" button that calls `audit.export_bundle` via MCP
- [ ] Add "Verify" badge showing chain status

### 3.3 Recommendation

**Defer WebUI to post-MVP.** The MCP auditor + Needle transport + four audit tools + verify.py is a complete, shippable product. The WebUI is a demo, not a requirement. Build it only if there's demand.

---

## Phase 4: Distribution & Polish

### 4.1 Packaging

- `mix escript.build` → `shem_audit` binary (1.6 MB; `app: nil`, no embedded runtime)
- `verify.py` is embedded at compile time, so it ships inside the binary already
- **No build matrix.** `file shem_audit` reports a zip of BEAM bytecode behind a
  `#!/usr/bin/env escript` shebang: architecture- and libc-independent. Building
  Linux x86_64/aarch64 and macOS variants would emit four identical files. One
  job, one artifact, any host with an Erlang runtime.

### 4.2 Documentation

`README.md` already covers the quickstart, Needle install and `NEEDLE_PATH`, the
`verify.py` walkthrough, and the fork/recall tool surface. The separate
`NEEDLE.md`, `VERIFY.md` and `FORK_RECALL.md` planned here would duplicate it;
cut unless the README is later split.

### 4.3 Tasks

- [x] Configure escript build for cross-platform — nothing to configure, see 4.1
- [x] Add GitHub Actions workflow — `.github/workflows/build.yml`, unpushed, so
      it has never run on GitHub; the clean-room job was validated locally under
      podman
- [x] Test `shem_audit` binary on clean machine (no Elixir)

The clean room is `erlang:27-alpine` plus `python3`, run with `--network none`:
no Elixir, no mix, no deps, no fetch, and musl where the build was glibc. It
runs `test/mcp_smoke.py`, which drives the binary over real stdio and ends by
exporting a bundle and verifying it offline with the embedded `verify.py`.
Passing that is the portability claim, tested rather than asserted.

---

## Dependency graph (what blocks what)

```
Phase 0 (extract core)
    │
    ├──► Phase 1 (Needle transport)  ── can run in parallel after Phase 0
    │
    ├──► Phase 2 (MCP audit tools)   ── can run in parallel after Phase 0
    │
    └──► Phase 3 (WebUI)             ── optional, depends on Phase 0 + Phoenix deps
```

**Critical path:** Phase 0 → Phase 1 + Phase 2 (parallel) → Phase 4

---

## Estimated effort

| Phase | Scope | Est. days |
|---|---|---|
| 0 | Extract core, escript | 2-3 |
| 1 | Needle transport | 1-2 |
| 2 | Four MCP audit tools | 1-2 |
| 3 | WebUI (optional) | 3-5 |
| 4 | Distribution + docs | 1-2 |
| **Total (MVP)** | **Phases 0, 1, 2, 4** | **5-9 days** |

---

## Open questions before starting

1. **Needle binary path resolution** — **DECIDED: keep the `NEEDLE_PATH`
   prerequisite.** No bundling, no runtime download. A later install script may
   fetch it and help with configuration, prompting for permission before it
   touches anything.
2. **MCP server transport** — **DECIDED: stdio only.** The MCP spec (rev
   2026-07-28) defines two bindings, stdio and Streamable HTTP; the two-endpoint
   "HTTP+SSE" transport named in the original question no longer exists, and SSE
   survives only as one of the reply shapes a Streamable HTTP POST can return.
   Streamable HTTP exists to cross a network boundary, which this tool does not
   have: it reads a local event log. Adding it would buy session management,
   Origin validation against DNS rebinding, and an auth story, against a product
   claim of offline verifiability and a hard loopback bind. Revisit only if the
   auditor ever runs on a different host from the agent it records.
3. **Session storage** — DETS per-session (current) or Mnesia? DETS is simpler for single-node; Mnesia adds clustering but complexity. Spec says DETS for MVP.
4. **Config file location** — `~/.config/shem_spolia/config.exs`? Environment variables only? CLI flags?

---

## Quickstart validation (what "done" looks like for MVP)

```bash
# 1. Build
mix escript.build
# → shem_audit binary

# 2. Run auditor (stdio MCP)
./shem_audit

# 3. In another terminal, connect Claude Code:
# claude mcp add shem-audit ./shem_audit

# 4. Ask Claude to do something that uses tools
# → events logged to hash chain

# 5. In Claude: "Use the audit.export_bundle tool for this session"
# → bundle written to ./audit_bundle_<timestamp>/

# 6. Verify anywhere:
python3 ./audit_bundle_<timestamp>/verify.py
# → "Chain valid: ✓"

# 7. Test Needle transport:
# config :shem_spolia, :llm_routes, %{needle: {:needle, "/path/to/needle"}}
# In agent config: brain: {:model, "needle"}
# → agent runs with local Needle, events logged identically
```

---

## File inventory (what exists in Shem to copy/adapt)

```
lib/shem/event_log.ex              → lib/shem_spolia/event_log.ex
lib/shem/event_log/chain.ex        → lib/shem_spolia/event_log/chain.ex
lib/shem/attest/canonical_json.ex  → lib/shem_spolia/event_log/canonical_json.ex
lib/shem/event_log/redact.ex       → lib/shem_spolia/event_log/redact.ex
lib/shem/event_log/gc.ex           → lib/shem_spolia/event_log/gc.ex
lib/shem/attest.ex                 → lib/shem_spolia/attest.ex
lib/shem/mcp/server.ex             → lib/shem_spolia/mcp/server.ex
lib/shem/mcp/router.ex             → lib/shem_spolia/mcp/router.ex
lib/shem/llm/middleware.ex         → lib/shem_spolia/llm/middleware.ex
lib/shem/llm/response.ex           → lib/shem_spolia/llm/response.ex
lib/shem/llm/middleware/ollama_transport.ex   → template for NeedleTransport
lib/shem/llm/middleware/llama_cpp_transport.ex → template for NeedleTransport
lib/shem/lab/port_pool.ex          → reference for Port.open pattern
lib/shem/recall/                   → lib/shem_spolia/recall/
priv/attest/verify.py              → priv/attest/verify.py (copy verbatim)
```

---

## Next action

Pick the first task from Phase 0 and start. Recommended order:

1. `shem-spolia/mix.exs` — defines everything else
2. Copy `verify.py` — the trust anchor
3. Extract `EventLog.Chain` + `CanonicalJSON` — pure logic, no deps
4. Extract `Attest.build/2` — produces the bundle
5. Extract `MCP.Server` + `MCP.Router` — the auditor surface
6. Write the four `audit.*` tools
7. Write `Application` + `CLI` + escript config
8. Test end-to-end with `./shem_audit` + Claude Code

Want me to start on any specific task, or do you want to review this plan first?
/* ══════════════════════════════════════════════════════════════════════════
   shem-spolia — CUSTODY UI

   Preact + htm, no build step: htm parses the tagged templates at runtime, so
   the file you read here is the file the binary serves. That matters more than
   usual for a tool whose pitch is "you can check this yourself" — a bundled,
   minified UI would be the one part of the system nobody could audit.
   ══════════════════════════════════════════════════════════════════════════ */

import { html, render, useState, useEffect, useRef, useCallback }
  from "/vendor/preact.js";

/* ── data access ─────────────────────────────────────────────────────── */

async function api(path, opts) {
  const res = await fetch(path, opts);
  let body = null;
  try { body = await res.json(); } catch (_) { /* non-JSON error page */ }
  if (!res.ok) {
    const msg = (body && (body.error || body.detail)) || `HTTP ${res.status}`;
    const err = new Error(msg);
    err.status = res.status;
    err.body = body;
    throw err;
  }
  return body;
}

const post = (path, payload) =>
  api(path, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(payload || {}),
  });

/* ── formatting ──────────────────────────────────────────────────────── */

// Timestamps are shown as time-of-day: this is a forensic log read within one
// session far more often than across days, and the full ISO stamp is one hover
// away in the title attribute.
const clock = (iso) => (iso ? iso.slice(11, 23) : "--:--:--.---");

// Hashes read as two 16-char groups. Full value stays in the title attribute —
// truncation is for scanning, never for hiding evidence.
const hashPair = (h) =>
  !h ? "" : `${h.slice(0, 16)} ${h.slice(16, 32)}`;

const EVENT_CLASS = {
  llm_call_started: "llm",
  llm_call_completed: "llm",
  agent_tool_called: "tool",
  tool_invoked: "tool",
  agent_tool_result: "result",
  fork_created: "fork",
  counterfactual_turn: "fork",
};
const klass = (type) => EVENT_CLASS[type] || "";

const label = (type) => type.replace(/_/g, " ");

/* Payload summary: the two or three fields worth reading on a folded sheet.
   Prefers the keys that carry meaning for an auditor, then falls back to
   whatever the payload has. Never fabricates — if there is nothing readable it
   says so and the full payload is one click away. */
const PREFERRED = ["prompt", "model", "tool", "args", "arguments", "content",
                   "confidence", "calls", "ok", "error", "reason",
                   "parent_session", "fork_point", "role"];

function summarize(payload) {
  if (!payload || typeof payload !== "object") return [];
  const keys = Object.keys(payload);
  const ordered = [
    ...PREFERRED.filter((k) => keys.includes(k)),
    ...keys.filter((k) => !PREFERRED.includes(k)),
  ];
  return ordered.slice(0, 3).map((k) => [k, render_value(payload[k])]);
}

function render_value(v) {
  if (v === null || v === undefined) return "—";
  if (typeof v === "string") return v.length > 90 ? v.slice(0, 90) + "…" : v;
  if (typeof v === "object") {
    const s = JSON.stringify(v);
    return s.length > 90 ? s.slice(0, 90) + "…" : s;
  }
  return String(v);
}

/* ── components ──────────────────────────────────────────────────────── */

function Docket({ stats, connected }) {
  const s = stats || {};
  return html`
    <div class="docket">
      <div class="line">
        <h1>Shem·Spolia</h1>
        <span class="sub">chain of custody</span>
        <div class="no">
          LOG <b>${s.log_path || "—"}</b><br/>
          VER <b>${s.version || "—"}</b>${"\u00a0\u00a0"}
          NEEDLE <b>${s.needle ? "present" : "absent"}</b>${"\u00a0\u00a0"}
          FEED <b class=${connected ? "live" : "dead"}>${connected ? "live" : "offline"}</b>
        </div>
      </div>
    </div>
    <div class="underline2"></div>
  `;
}

function Counts({ stats }) {
  const s = stats || {};
  const f = (k) => (s[k] === undefined ? "—" : s[k]);
  return html`
    <div class="form">
      <div class="field"><div class="k">sessions held</div><div class="v">${f("sessions")}</div></div>
      <div class="field"><div class="k">verified</div><div class="v grn">${f("verified")}</div></div>
      <div class="field"><div class="k">broken seal</div><div class="v red">${f("broken")}</div></div>
      <div class="field"><div class="k">legacy</div><div class="v">${f("legacy")}</div></div>
      <div class="field"><div class="k">events</div><div class="v">${f("events")}</div></div>
    </div>
  `;
}

function Tabs({ sessions, selected, onSelect }) {
  return html`
    <aside class="tabs">
      <h2>custody file <span class="n">${sessions.length}</span></h2>
      ${sessions.length === 0 &&
        html`<div class="empty-note">No sessions recorded yet.<br/>Run an audited turn to open one.</div>`}
      ${sessions.map((s) => {
        const v = s.verify || {};
        const tick = v.state === "verified" ? "ok" : v.state === "broken" ? "bad" : "warn";
        const mark = v.state === "verified" ? "✓" : v.state === "broken" ? "✕" : "▲";
        const word =
          v.state === "verified" ? `verified · ${s.events} events`
          : v.state === "broken" ? `seal broken`
          : `${v.state} · ${s.events} events`;
        return html`
          <button class=${"tab" + (s.id === selected ? " sel" : "")}
                  onClick=${() => onSelect(s.id)} key=${s.id}>
            <div class="id">${s.id}</div>
            <div class="st"><span class=${"tick " + tick}>${mark}</span> ${word}</div>
            ${s.fork_of && html`<div class="clip">branch</div>`}
          </button>
        `;
      })}
    </aside>
  `;
}

function Disposition({ verify }) {
  const v = verify || {};
  const cls = v.state === "verified" ? "ok" : v.state === "broken" ? "bad" : "warn";
  const word =
    v.state === "verified" ? "verified"
    : v.state === "broken" ? "seal broken"
    : v.state === "legacy" ? "legacy · unhashed"
    : v.state || "unknown";
  const ref =
    v.state === "broken" ? `at ${v.broken_at}`
    : v.detail ? v.detail
    : v.count !== undefined ? `${v.count} entries chained` : "";
  return html`
    <div class="disp">
      <span class="lbl">disposition</span>
      <span class=${"val " + cls}>${word}</span>
      <span class="ref">${ref}</span>
    </div>
  `;
}

function Entry({ ev, broken_at, isHead, expanded, onToggle }) {
  // An entry is "cut" only at the exact event the chain verifier named. Marking
  // every subsequent event as broken would overstate the finding: we know where
  // the chain stops proving things, not that each later event was altered.
  const cut = broken_at && ev.id === broken_at;
  const cls = ["entry", cut ? "cut" : klass(ev.type), expanded ? "sel" : ""]
    .filter(Boolean).join(" ");
  const pairs = summarize(ev.payload);

  return html`
    <div class=${cls}>
      <div class="knot"></div>
      ${cut && html`<span class="margin-note bad">altered on disk</span>`}
      ${!cut && isHead && html`<span class="margin-note">head ↴</span>`}
      <div class="slipcard" onClick=${onToggle}>
        <div class="r1">
          <span class="ty">${label(ev.type)}</span>
          <span class="tm" title=${ev.timestamp}>${clock(ev.timestamp)}</span>
        </div>
        ${pairs.length > 0 && html`
          <div class="bd">
            ${pairs.map(([k, v], i) => html`
              ${i > 0 ? " — " : ""}${k} <em>${v}</em>
            `)}
          </div>`}
        <div class="hx" title=${ev.hash || ""}>
          ${cut
            ? "✕ recorded hash does not match these bytes"
            : hashPair(ev.hash) || "(unhashed)"}
        </div>
        ${expanded && html`
          <div class="payload">${JSON.stringify(ev.payload, null, 2)}</div>`}
      </div>
    </div>
  `;
}

function Exhibit({ sessionId, detail, onFork, onAttest, onVerify, busy, finding }) {
  const [open, setOpen] = useState(null);

  if (!sessionId) {
    return html`<main class="exhibit">
      <h2>exhibit</h2>
      <div class="card"><div class="empty-note">Select a session from the custody file.</div></div>
    </main>`;
  }
  if (!detail) {
    return html`<main class="exhibit">
      <h2>exhibit</h2>
      <div class="card"><div class="empty-note">Reading chain…</div></div>
    </main>`;
  }

  const v = detail.verify || {};
  const broken = v.state === "broken";
  const events = detail.events || [];
  const headId = events.length ? events[events.length - 1].id : null;

  return html`
    <main class="exhibit">
      <h2>exhibit <span class="n">event chain</span></h2>
      <div class=${"card" + (busy ? " busy" : "")}>
        <div class="cardhead">
          <span class="sid">${sessionId}</span>
          <span class="meta">${detail.count} entries · sha-256 chained</span>
        </div>
        <${Disposition} verify=${v} />

        <div class=${"log" + (events.length ? "" : " empty")}>
          ${events.length === 0 && html`<div class="empty-note">No events in this session.</div>`}
          ${events.map((ev) => html`
            <${Entry} key=${ev.id} ev=${ev} broken_at=${v.broken_at}
                      isHead=${ev.id === headId && !broken}
                      expanded=${open === ev.id}
                      onToggle=${() => setOpen(open === ev.id ? null : ev.id)} />
          `)}
        </div>

        <div class="strip">
          <button class="st go" disabled=${broken || busy} onClick=${onAttest}>issue bundle</button>
          <button class="st" disabled=${broken || busy} onClick=${onFork}>fork here</button>
          <button class="st" disabled=${busy} onClick=${onVerify}>re-verify</button>
        </div>

        ${broken && html`
          <div class="finding">
            <b>No bundle will be issued from this session.</b>
            ${" Everything at and after "}${v.broken_at}${" is unattested; recall excludes it from memory."}
          </div>`}
        ${finding && html`
          <div class=${"finding" + (finding.ok ? " ok" : "")}>
            <b>${finding.title}</b> ${finding.text}
            ${finding.path && html`<span class="path">${finding.path}</span>`}
          </div>`}
      </div>
    </main>
  `;
}

function Recall({ results, query, onQuery, onOpen }) {
  return html`
    <div class="search">
      <span class="lbl">recall</span>
      <input value=${query} placeholder="search every verified session…"
             onInput=${(e) => onQuery(e.target.value)} />
    </div>
    ${results && html`
      <div style="margin-bottom:22px">
        ${(results.skipped || []).map((s) => html`
          <div class="skipped" key=${s.session_id}>
            <b>excluded:</b> ${s.session_id} — ${s.reason}
          </div>`)}
        ${(results.hits || []).length === 0 &&
          html`<div class="empty-note">No matches across ${results.indexed_sessions} indexed session(s).</div>`}
        ${(results.hits || []).map((h) => html`
          <div class="hit" key=${h.session_id + h.event_id} onClick=${() => onOpen(h.session_id)}>
            <div class="r1">
              <span class="sid">${h.session_id} · ${h.type || "?"}</span>
              <span class="score">${h.score}</span>
            </div>
            <div class="snip">${h.snippet || "(no text)"}</div>
          </div>`)}
      </div>`}
  `;
}

function ForkModal({ onCancel, onSubmit, error, busy }) {
  const [text, setText] = useState(
    '{\n  "role": "assistant",\n  "content": "refused: no declared tool serves this"\n}'
  );
  const ref = useRef(null);
  useEffect(() => { ref.current && ref.current.focus(); }, []);

  return html`
    <div class="backdrop" onClick=${(e) => e.target === e.currentTarget && onCancel()}>
      <div class="modal">
        <h3>fork — alternative turn</h3>
        <div class="mbody">
          <label>alt_response (JSON object)</label>
          <textarea ref=${ref} value=${text}
                    onInput=${(e) => setText(e.target.value)}></textarea>
          <div class="hint">
            The branch is a real session with its own chain, anchored at its own id.
            Its first event records this parent and the parent's head, so the
            descent claim is checkable.
          </div>
          ${error && html`<div class="err">${error}</div>`}
        </div>
        <div class="strip">
          <button class="st go" disabled=${busy} onClick=${() => onSubmit(text)}>create branch</button>
          <button class="st" disabled=${busy} onClick=${onCancel}>cancel</button>
        </div>
      </div>
    </div>
  `;
}

/* ── app ─────────────────────────────────────────────────────────────── */

function App() {
  const [stats, setStats] = useState(null);
  const [sessions, setSessions] = useState([]);
  const [selected, setSelected] = useState(null);
  const [detail, setDetail] = useState(null);
  const [connected, setConnected] = useState(false);
  const [busy, setBusy] = useState(false);
  const [finding, setFinding] = useState(null);
  const [forking, setForking] = useState(false);
  const [forkError, setForkError] = useState(null);
  const [query, setQuery] = useState("");
  const [results, setResults] = useState(null);

  const loadDetail = useCallback(async (id) => {
    if (!id) { setDetail(null); return; }
    try {
      setDetail(await api(`/api/sessions/${encodeURIComponent(id)}/events`));
    } catch (e) {
      setDetail({ events: [], count: 0, verify: { state: "not_found" } });
    }
  }, []);

  // Initial paint, then SSE takes over. The stream carries sessions+stats, so
  // steady state costs no polling from the browser.
  useEffect(() => {
    (async () => {
      try {
        const [st, ss] = await Promise.all([api("/api/stats"), api("/api/sessions")]);
        setStats(st);
        setSessions(ss.sessions);
        if (!selected && ss.sessions.length) setSelected(ss.sessions[0].id);
      } catch (_) { /* the stream will retry */ }
    })();

    const es = new EventSource("/api/stream");
    es.onopen = () => setConnected(true);
    es.onerror = () => setConnected(false);
    es.addEventListener("sessions", (e) => {
      setConnected(true);
      const data = JSON.parse(e.data);
      setSessions(data.sessions);
      setStats(data.stats);
    });
    return () => es.close();
  }, []);

  useEffect(() => { loadDetail(selected); }, [selected, loadDetail]);

  // A live chain can change under us (the auditor is still recording). When the
  // selected session's head moves, re-read it — otherwise the sheet silently
  // goes stale while the feed claims to be live.
  const headOf = (id) => {
    const s = sessions.find((x) => x.id === id);
    return s ? s.head : null;
  };
  const selectedHead = headOf(selected);
  useEffect(() => { if (selected) loadDetail(selected); }, [selectedHead]);

  useEffect(() => {
    if (!query.trim()) { setResults(null); return; }
    const t = setTimeout(async () => {
      try {
        setResults(await api(`/api/recall?q=${encodeURIComponent(query)}&limit=20`));
      } catch (_) { setResults({ hits: [], skipped: [], indexed_sessions: 0 }); }
    }, 220);
    return () => clearTimeout(t);
  }, [query]);

  const select = (id) => { setSelected(id); setFinding(null); };

  const doVerify = async () => {
    setBusy(true); setFinding(null);
    try {
      const v = await api(`/api/sessions/${encodeURIComponent(selected)}/verify`);
      setDetail((d) => (d ? { ...d, verify: v } : d));
      setFinding({
        ok: v.state === "verified",
        title: v.state === "verified" ? "Chain re-verified." : "Chain not verified.",
        text: v.state === "verified"
          ? `${v.count} entries recomputed from genesis; every hash matches.`
          : v.broken_at ? `Mismatch at ${v.broken_at}.` : (v.detail || ""),
      });
    } catch (e) {
      setFinding({ title: "Verify failed.", text: e.message });
    } finally { setBusy(false); }
  };

  const doAttest = async () => {
    setBusy(true); setFinding(null);
    try {
      const r = await post(`/api/sessions/${encodeURIComponent(selected)}/attest`, {});
      const m = r.manifest || {};
      const missing = (m.tools || []).filter((t) => t.status !== "present");
      setFinding({
        ok: true,
        title: "Bundle issued.",
        text: `${m.event_count} events, portable head ${(m.portable_head || "").slice(0, 16)}…` +
              (missing.length
                ? ` Tool source MISSING for ${missing.map((t) => t.name).join(", ")} — recorded as such.`
                : ""),
        path: r.verify_command,
      });
    } catch (e) {
      setFinding({
        title: "Bundle refused.",
        text: e.body && e.body.broken_at ? `${e.message} at ${e.body.broken_at}.` : e.message,
      });
    } finally { setBusy(false); }
  };

  const doFork = async (text) => {
    let alt;
    try { alt = JSON.parse(text); }
    catch (e) { setForkError("Not valid JSON: " + e.message); return; }
    if (!alt || typeof alt !== "object" || Array.isArray(alt)) {
      setForkError("alt_response must be a JSON object.");
      return;
    }
    setBusy(true); setForkError(null);
    try {
      const r = await post(`/api/sessions/${encodeURIComponent(selected)}/fork`,
                           { alt_response: alt });
      setForking(false);
      setFinding({
        ok: true,
        title: "Branch created.",
        text: `${r.fork_session_id} — ${r.copied} events copied, forked at ${r.fork_point}. ` +
              `It verifies on its own chain.`,
      });
      setSelected(r.fork_session_id);
    } catch (e) {
      setForkError(e.message);
    } finally { setBusy(false); }
  };

  return html`
    <div class="sheet">
      <${Docket} stats=${stats} connected=${connected} />
      <${Counts} stats=${stats} />
      <${Recall} results=${results} query=${query} onQuery=${setQuery} onOpen=${select} />
      <div class="grid">
        <${Tabs} sessions=${sessions} selected=${selected} onSelect=${select} />
        <${Exhibit} sessionId=${selected} detail=${detail} busy=${busy} finding=${finding}
                    onVerify=${doVerify} onAttest=${doAttest}
                    onFork=${() => { setForkError(null); setForking(true); }} />
      </div>
      <div class="sig">
        <span>recorded by shem·spolia ${(stats && stats.version) || ""}</span>
        <span>127.0.0.1 only</span>
        <span>no network egress</span>
      </div>
      ${forking && html`
        <${ForkModal} onCancel=${() => setForking(false)} onSubmit=${doFork}
                      error=${forkError} busy=${busy} />`}
    </div>
  `;
}

render(html`<${App} />`, document.getElementById("root"));

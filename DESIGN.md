# Design — CUSTODY

Visual system for the shem-spolia web surface.

The premise the whole design follows from: **this tool's output is an exhibit.**
A bundle gets handed to someone who was not there, has no access to the machine
that produced it, and no reason to trust the person handing it over. The UI's
job is not to look like a monitoring dashboard. It is to look like the thing you
hand to a stranger who is going to check your work.

So the surface is a **carbon copy of a chain-of-custody sheet**: typed, ruled,
punched, folded, threaded. Dark stock, because this is the copy that stays with
the recorder.

## What this is a reaction against

Named explicitly so the next change does not drift back into it:

- No floating pill navigation, no rounded-xl cards, no soft blur drop shadows.
- No blue→purple gradients. No gradient anything, except grain and paper fold.
- No rubber stamps, no skeuomorphic seals, no torn-paper edges. Those read as
  advertising. Disposition is **typed onto a ruled line**, because a machine
  types; it does not stamp.
- No blue-grey "dark slate" palette. Slate is the default of every developer
  tool built since 2019 and it destroys the paper reading instantly.

## Stock and ink

Warm brown-black, never blue. The neutrals carry the surface; color is reserved
for disposition, event class, and the thread.

```css
--stock:    #131110;  /* page — carbon stock */
--sheet:    #1a1715;  /* the document surface */
--sheet-2:  #211d1a;  /* raised: entries, form fields */
--sheet-3:  #0f0d0c;  /* recessed: punch wells */
--rule:     #322c26;  /* hairline rules, 1px */
--rule-2:   #453d34;  /* emphasized rules, card borders */

--ink:      #ded4c1;  /* primary — bone, carbon-transferred */
--ink-2:    #9c9280;  /* secondary — body copy, payloads */
--ink-3:    #6d6555;  /* tertiary — labels, meta, timestamps */
```

`--ink` and `--ink-2` both clear 4.5:1 on `--sheet`. `--ink-3` is for uppercase
labels and meta only — never body text.

## Semantic color

Five colors, each with a job. Every one is paired with a glyph or a word, never
color alone.

```css
--thread:   #c4453a;  /* the chain itself. red string. */
--ok:       #6fbf8e;  /* verified            ✓ */
--bad:      #e8695c;  /* broken seal         ✕ */
--amber:    #d9a441;  /* tool events; emphasis underline */
--pencil:   #7fa8d4;  /* annotation pencil; llm events */
```

`--thread` is structural, not decorative: it is the hash chain rendered as a
physical object. It appears nowhere else.

## The three signatures

If a future change keeps nothing else, keep these. They are the design.

**1. The thread, and cutting it.** Events hang off a 2px red line with knots at
each entry. At a hash mismatch the knot goes solid red and **the thread below it
is severed** — a stock-colored block covers it. Chain integrity is not a badge in
the corner; it is whether the string is still in one piece.

**2. Disposition is typed, not stamped.**

```
DISPOSITION   ___VERIFIED___     portable head a81dff08d9cc712f
```

An uppercase value on a 1px underline, with the head hash as a reference number.
Quiet, and it makes the verdict a field on a form rather than a graphic.

**3. Refusals are struck out.** When a chain is broken, `issue bundle` and
`fork here` are disabled **with `line-through`**. The sheet shows that the
export was struck out — it does not silently hide the control. The refusal is
the product working, so it is visible.

## Paper effects

Three, all cheap, all inline SVG (no image requests — the CSP forbids remote
ones anyway):

- **Carbon tooth** — `feTurbulence` at `baseFrequency .6`, `opacity .13`,
  `mix-blend-mode: soft-light`. Soft-light, not multiply: multiply on dark stock
  muddies it.
- **The fold** — two 0.2%-wide light bands at 33% and 66.5%. The sheet was
  folded in thirds before it reached you. On dark stock creases catch light,
  so they are light, not shadow.
- **Punch wells** — repeating radial-gradient down the left margin: dark hole
  with a `#ffffff0e` lit lower lip, so it reads as a hole in a surface rather
  than a printed dot.

## Type

One family, everywhere: **Courier Prime** (SIL OFL), self-hosted, three faces
(regular/bold/italic, ~85 KB woff2 total). A typed document has one typewriter.

Self-hosting is a constraint, not a preference: the CSP is `default-src 'self'`
and the tool claims no network egress, so a font CDN would be the auditor
phoning home on page load. Fonts are embedded in the binary at compile time
alongside `verify.py`.

Italic carries margin annotations (`head ↴`, `altered on disk`) — the blue-pencil
marks a reviewer leaves. Do not substitute a script/handwriting face; it was
tried and it reads as a greeting card.

```css
--ff: "Courier Prime","Courier New",ui-monospace,monospace;
```

Scale is small and dense: 9–10px uppercase labels with `.14–.19em` tracking,
12–13px body, 17–21px for figures and the title. Numerals are
`font-variant-numeric: tabular-nums` everywhere — columns of hashes and counts
must align.

## Emphasis

On light stock, emphasis was a yellow highlighter block. On dark that is
unreadable, so emphasis is **full-strength ink plus a 1px amber underline**
(`box-shadow: inset 0 -1px 0 var(--amber)`). Used for the values that matter in
a payload — model names, tool names, arguments.

## Depth and press

Depth comes from hard offsets, never blur:

- Cards: `box-shadow: 0 2px 0 #00000060` — a sheet lying on a sheet.
- Buttons: `2px 2px 0` hard shadow; on `:active`, `translate(2px,2px)` and the
  shadow goes to zero. The key travels. No color-change-only press states.
- Raised surfaces get `inset 0 1px 0 #ffffff07` — one lit pixel on the top edge.
- Radii: 0 everywhere. This is paper, not a widget.

## Layout

A 1060px sheet with a punched left margin. Two columns: 264px custody file
(session tabs) and the exhibit (event chain). Selected tabs are marked by a red
left edge, not a fill — the thread color again, tying selection to the chain.

## Accessibility floor

- Every state has a glyph and a word: `✓ verified`, `✕ seal broken`. Color is
  never the only channel — the whole design survives greyscale, which matters
  more here than usual because these screens get printed.
- Focus is a visible 1px `--amber` outline with a 2px offset; it is never
  removed.
- Disabled controls keep their text legible (`opacity .42` + `line-through`)
  rather than fading to invisibility. A refusal the user cannot read is a bug.

# Third-party components

`shem_audit` vendors three third-party artifacts into `priv/web/` and embeds
them in the built binary. They are listed here with their licenses because a
tool that argues for provenance should be able to account for its own.

Nothing else in the binary is third-party: the runtime dependency set is
`jason` alone (`ex_doc` and `dialyxir` are dev-only), plus OTP itself.

---

## Preact + htm — `priv/web/preact.js`

The UI runtime, vendored as a single pre-built ESM file
(`htm@3.1.1/preact/standalone.module.js`) so the project needs no node, npm, or
bundler.

- **Preact** — MIT License, Copyright (c) 2015-present Jason Miller
  <https://github.com/preactjs/preact>
- **htm** — Apache License 2.0, Copyright (c) 2018 Jason Miller
  <https://github.com/developit/htm>

The file is unmodified upstream output. To refresh it:

```bash
curl -sSL -o priv/web/preact.js \
  https://unpkg.com/htm@3.1.1/preact/standalone.module.js
```

## Courier Prime — `priv/web/fonts/*.woff2`

The UI typeface, three faces (Regular, Bold, Italic) converted from the upstream
TTFs with `woff2_compress`. ~85 KB total.

- **SIL Open Font License 1.1**, Copyright 2015 The Courier Prime Project Authors
  <https://github.com/quoteunquoteapps/CourierPrime>
- Full license text ships alongside the fonts at `priv/web/fonts/OFL.txt` and is
  served by the binary at `/fonts/OFL.txt`.

Self-hosted rather than loaded from a font CDN: the WebUI's CSP is
`default-src 'self'` and the tool claims no network egress, so a remote font
request would be the auditor phoning home on page load.

The OFL permits bundling and redistribution as part of a larger work. The fonts
are unmodified apart from the WOFF2 container; the Reserved Font Name clause is
not engaged because they are not renamed.

---

## What is NOT vendored

`priv/attest/verify.py` is first-party and deliberately stdlib-only — no
dependencies at all, so a bundle can be verified on a machine with nothing but
Python 3.

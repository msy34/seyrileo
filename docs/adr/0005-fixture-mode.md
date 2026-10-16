# ADR 0005 — Fixture mode ("sample experience")

Status: accepted for development builds; release inclusion **open**

## Decision

`SeyrileoFixtureServer` is an in-process HTTP server bound to **127.0.0.1 only** (fixed
port 47816 in the app, random port in tests). It serves:

- Xtream-shaped JSON for auth, live categories and live streams, with deliberate type
  variations (numbers vs strings, nulls, entries missing IDs).
- Two live sliding-window HLS channels looping 20 s of generated media (with correct
  discontinuity sequencing), plus failure scenarios: live raw TS (no length/ranges),
  404, 403, corrupt segments.
- Fixture credentials `seyrileo-demo` / `fixture pass/#?&+%`. The password deliberately
  contains reserved URL characters so path/query encoding is exercised end-to-end.

The "Try the sample experience" button creates an ordinary `ProviderSource` of kind
`.fixture` through the **same** verify → Keychain → JSON path as real sources. It is
labeled everywhere (welcome text, Live banner, player badge, Settings row).

## Media rights

All media is produced by `scripts/generate-fixture-media.sh` using ffmpeg's `testsrc2`,
`smptehdbars` and `sine` generators. No third-party footage, logos or artwork. ~1.7 MB.

## Not claimed

Fixture results are not real-provider results and simulator results are not device results.
A bundled demo is not automatically a substitute for an App Review test account.

## Note (Milestone 2)

The fixture server is now reached through the global `NSAllowsArbitraryLoads` ATS setting
(ADR 0004); `NSAllowsLocalNetworking` was removed because its presence would disable that key.

## Open

Whether to ship the fixture server in release builds (useful as a no-account demo; adds a
loopback listener and ~2 MB). Decide in Milestone 5 with App Review guidance.

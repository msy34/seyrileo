# Risk list — security, rights, compatibility, release

Severity: H/M/L. Owner: **Dev** (code), **Owner** (business/legal/Apple account).

## Security

| # | Risk | Sev | Mitigation now | Remaining |
|---|---|---|---|---|
| S1 | Password leaks via stream URLs (password is in the path) | H | `Redactor` reduces every URL to origin, scrubs raw/encoded secrets; `PlaybackItem` & credentials print redacted; tests with reserved characters; idempotence test | Audit future crash reporter / analytics before adding any |
| S2 | Secrets persisted in caches/cookies | M | Ephemeral URLSession; no image loading yet; container grep showed none | Image loader (M2) must not cache secret-bearing URLs |
| S3 | Plain HTTP exposes credentials | H | Owner decision: HTTP supported (`NSAllowsArbitraryLoads`); HTTPS default, no downgrade, warning before saving an HTTP source | Inherent for HTTP providers; App Review may question the exception (R5) |
| S4 | Provider redirects credentials to another host | M | Same-host-only metadata redirects | AVPlayer media redirects not controllable (documented) |
| S5 | Keychain items survive uninstall | L | Orphan pruning at launch | — |
| S6 | Fixture listener reachable from network | L | Bound to 127.0.0.1 only | Decide release inclusion (ADR 0005) |
| S7 | Huge / hostile responses | M | Streaming size caps, lossy decoding, timeouts | XMLTV parser caps in M4 |

## Rights & content

| # | Risk | Sev | Mitigation | Remaining |
|---|---|---|---|---|
| R1 | App perceived as piracy tool | H | Copy says "player only, add a source you're authorized to use"; no content bundled or recommended | Store copy & screenshots review (M5) |
| R2 | Third-party logos/posters in demo/screenshots | H | Monogram avatars; generated test patterns only | Screenshot audit (M5) |
| R3 | VLCKit LGPL obligations / codec patents | H | Integrated by owner decision (2026-10-15): unmodified, dynamically linked, in-app license + source link | **Legal review before any distribution** (relinking on App Store, codec patents) — ADR 0003 |
| R5 | App Review rejects or questions `NSAllowsArbitraryLoads` | M | Review-note draft in ADR 0004; safeguards documented | Owner to submit with justification; fallback HTTPS-only build |
| R4 | Brand "Seyrileo" not cleared | M | Display name is a build setting; storage keys brand-neutral | **Owner**: TÜRKPATENT/WIPO, domain, App Store name |

## Compatibility

| # | Risk | Sev | Mitigation | Remaining |
|---|---|---|---|---|
| C1 | Live `.ts` output unsupported by AVPlayer | H | Prefer HLS; one fallback to VLC | Device verification |
| C2 | Provider API variations | M | Lenient decoding, dropped-entry counts, explicit errors | **Real-provider validation pending** |
| C3 | Reserved characters in credentials not decoded by some panels | M | Strict RFC 3986 encoding | Verify with real providers |
| C4 | AVPlayer silent hang on bad media | M | 20 s startup watchdog | Tune on device |
| C5 | One-connection subscriptions | M | Single engine invariant (tested ×100 switches), no previews/preopen | Measure server-side session release on real provider |
| C7 | Real provider's live audio is MPEG-1 Layer II, which AVPlayer cannot decode | H | Falls back to VLC | Device verification; VLC has no AirPlay video |
| C8 | Provider media hosts change per channel (IPs + other domains) over HTTP | H | `NSAllowsArbitraryLoads` (ADR 0004) | — |
| C9 | Large catalogues (24k+ movies) | M | Live catalogue in DB with FTS; per-source transactions | Measure write time/memory on device; page VOD in M3 |
| C6 | Simulator ≠ device (PiP, AirPlay, decoding, memory) | M | Capabilities shown as "Not verified" | Device matrix (M4) |

## Release blockers (owner-supplied; nothing invented)

- Bundle ID `com.msy.seyrileo` (chosen 2026-10-25); development team set to the owner's team for device testing
- Privacy policy URL, support URL, business/contact details
- App Store product ID for Pro, pricing (StoreKit, M5)
- Authorized live review account + review notes; rights documentation for screenshots
- VLCKit legal review (LGPL relinking on App Store, codec patents) and stripping of armv7/simulator slices (ADR 0003)
- Privacy manifest assessment once dependencies exist (none today)

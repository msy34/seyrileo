# ADR 0004 — Network security, ATS and plain-HTTP providers

Status: **accepted (owner decision 2026-10-15): plain-HTTP sources are supported in Debug and
Release.** App Store approval is not guaranteed by anything in this ADR.

## Decision

`Config/Info.plist` (shared by Debug and Release) contains exactly one ATS key:

```xml
<key>NSAllowsArbitraryLoads</key><true/>
```

No other ATS keys are present on purpose: on iOS 10+ the presence of
`NSAllowsArbitraryLoadsForMedia`, `NSAllowsArbitraryLoadsInWebContent` or
`NSAllowsLocalNetworking` makes the system **ignore** `NSAllowsArbitraryLoads`.
`NSAllowsLocalNetworking` is no longer needed because the global key also covers the loopback
fixture server.

### Why this is the narrowest configuration that works

Measured with a real authorized provider (Milestone 1.5, evidence below):

| Option | Metadata (URLSession) | Media (AVFoundation) | Result |
|---|---|---|---|
| A. HTTPS-only | HTTP blocked | HTTP blocked | Rejects the owner's source; not acceptable per product decision |
| B. `NSAllowsArbitraryLoadsForMedia` | Not covered | Had **no effect** on the provider's HLS (CoreMedia −1022) | Not viable |
| D. `NSExceptionDomains` for the provider host | Works for that host | Fails: media is redirected to changing **IP addresses** and other domains, which per-domain exceptions cannot name; hosts are user-entered anyway | Not viable |
| **C. `NSAllowsArbitraryLoads`** | Works | Works | **Chosen** |

Metadata and media were evaluated separately; both need plain HTTP for this class of provider.

### Safeguards kept in code (independent of ATS)

- **No downgrade:** an `https://` source is only ever contacted over HTTPS. A missing scheme
  defaults to HTTPS. The metadata transport refuses any redirect from HTTPS to HTTP and any
  redirect to a different host (`unsafeRedirectBlocked`), so credentials are not forwarded.
- **TLS validation is never disabled** — there is no `URLSessionDelegate` trust override and
  no `NSExceptionAllowsInsecureHTTPLoads`/`NSExceptionMinimumTLSVersion` tweak for HTTPS.
- **Informed user:** when the entered address is `http://`, the setup screen states that the
  username, password and viewing activity travel unencrypted and recommends HTTPS.
- **Credentials:** Keychain only (ADR 0002); every URL in logs, diagnostics and the shareable
  report is reduced to `scheme://host:port/[redacted]` and secrets are scrubbed (`Redactor`).
- `server_info.url/port` from the provider is never used; requests go to the user-entered origin.
- Response caps: auth 1 MB, categories 4 MB, streams 64 MB. Timeouts 15 s / 90 s. Bounded retries.

### App Review notes (draft; review outcome not guaranteed)

> Seyrileo is a media player for IPTV services the user already subscribes to. Users enter
> their own provider's server address. Many such providers only offer plain HTTP and redirect
> streams to content-delivery hosts and IP addresses that are not known in advance, so
> per-domain ATS exceptions cannot be configured. `NSAllowsArbitraryLoads` is therefore set.
> The app never downgrades HTTPS sources to HTTP, never disables certificate validation, warns
> users before saving an unencrypted source, and stores provider credentials only in the
> Keychain. The app does not provide or link to any content.

Apple may still question or reject the exception; prepare to explain it in App Store Connect
and possibly to offer an HTTPS-only build. Treat this as a release risk (docs/RISKS.md).

## Known limits

- AVPlayer follows HLS redirects itself; we cannot apply the same-host rule to media
  without an `AVAssetResourceLoader` proxy (not planned). Documented risk.

## Milestone 1.5 evidence — real authorized plain-HTTP provider (2026-10-15)

Host names are deliberately omitted. iOS 27 Simulator, Debug build.

1. Per-domain exception (`NSExceptionDomains` → provider host, `NSExceptionAllowsInsecureHTTPLoads`)
   — URLSession metadata (auth, categories, lists) **worked**. AVPlayer playback **failed**
   with CoreMedia/NSURLError `-1022`.
2. System log showed the blocked media requests went to **other origins**: the provider
   redirects live HLS to changing CDN hosts — two raw IPv4 addresses and a different domain,
   all plain HTTP on port 8080. Per-domain exceptions cannot name IP addresses.
3. Adding `NSAllowsArbitraryLoadsForMedia` had **no effect** on these HLS loads (still `-1022`).
4. Debug-only `NSAllowsArbitraryLoads` (with no other ATS keys, because their presence makes iOS
   ignore it) removed the ATS failure; playback then failed for a codec reason (ADR 0003).

### Superseded

The Milestone 1.5 Debug-only configuration (`Config/Info-Debug.plist`, `Config/Debug.xcconfig`,
untracked `Config/Local.xcconfig`) was removed in Milestone 2 when the owner decided to support
HTTP sources in all configurations.

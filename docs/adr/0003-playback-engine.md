# ADR 0003 — Playback engines and VLCKit

Status: accepted (AVPlayer only); alternate engine **open**

## Decision

- `PlaybackEngine` protocol (load/play/pause/stop, event callback, `EngineCapabilities`) and
  a single `PlaybackCoordinator` that owns lifecycle:
  - a fresh engine per attempt; previous engine stopped *before* the next is created;
  - stale events ignored by attempt token;
  - bounded retries (2) for transient failures only;
  - startup watchdog (20 s) — AVPlayer was observed to wait silently forever on
    undecodable HLS segments;
  - at most one alternate engine, tried only after stopping the first, for
    `unsupportedFormat` / `serverIncompatible` / `startupTimedOut`.
- Milestone 1 ships **only AVPlayer** (`AVPlayerViewController` UI). PiP is disabled
  (`notEnabled`) until device-verified; AirPlay and track selection are `unverified`.
- Live streams get no fake resume offsets.

## Evidence (see docs/COMPATIBILITY.md)

AVFoundation plays HLS; **live MPEG-TS over HTTP (no length, no ranges) fails** on macOS and
the iOS 27 simulator. On the iOS simulator even a finite TS file with byte ranges fails
(-11828). Many Xtream providers offer `m3u8` too, which is why HLS is preferred when
`allowed_output_formats` includes it or does not say.

## VLCKit (not integrated)

Desk check on 2026-10-13 of github.com/videolan/vlckit (a mirror; canonical repo is
code.videolan.org/videolan/VLCKit):

- License stated as **LGPL-2.1 (or later)**. FAQ: proprietary apps may embed it if changes
  to VLCKit are published, users are told VLCKit is embedded, and users get access to the
  VLCKit source and their rights.
- iOS distribution documented as CocoaPods `MobileVLCKit ~> 3.3.0` or a Carthage binary; a
  `Package.swift` exists but SPM usage is undocumented; README requirements look stale.

Unresolved before any integration (owner + legal):

1. Exact artifact and version (3.x vs 4.x), how it is linked (static binary in an App Store
   app makes LGPL "relinking" obligations non-trivial), enabled modules.
2. Whether any bundled module is GPL-only; codec patent exposure (e.g. HEVC, AC-3).
3. Required notices, source offer and how they appear in-app.
4. Binary size, App Store review and privacy-manifest impact.

Until resolved, the product truthfully says live `.ts` needs an engine this build lacks.

## Milestone 1.5 evidence — real provider (2026-10-15)

Two live channels from a real authorized provider, HLS (`m3u8`) output, iOS 27 Simulator:
H.264 1920×1080 video decoded, but the audio is **MPEG-1 Layer II (`.mp2`)**. CoreMedia found no
audio decoder for it, could not build the render pipeline and halted with `'fmt?'`
(1718449215) wrapped in AVFoundation `-11800`. Now classified as `unsupportedFormat`.

MP2 audio is common in Turkish broadcast restreams, so **AVPlayer alone cannot play this
provider's live channels**. This raises the priority of the alternate-engine decision (VLCKit or
another FFmpeg-based engine) — still blocked on the licensing review above.

## Decision update (2026-10-15): VLCKit added as the alternate engine — owner choice "A"

Evidence that forced the decision: real provider container mix (Debug probe, list endpoints
only) — movies mkv 14,508 / unknown 7,858 / mp4 2,115 / avi 138; episodes of 5 series 67/67
mkv. AVPlayer alone can play ≈9 % of the movies.

**What was added**

- `MobileVLCKit 3.7.4` from VideoLAN's own server, URL and SHA-256 taken from the official
  CocoaPods spec and verified by `scripts/fetch-vlckit.sh`. Stored in `Vendor/` (git-ignored,
  ~970 MB unpacked incl. simulator and armv7 slices); the script re-fetches it.
- Dynamic framework, embedded and code-signed in the app; **unmodified**.
- `VLCEngine` (app target) implements `PlaybackEngine`. Engine order: items whose container is
  mkv/avi/wmv/flv/webm/… start in VLC; everything else starts in AVPlayer and switches **once**
  to VLC on `unsupportedFormat` / `serverIncompatible` / `startupTimedOut` (e.g. live HLS with
  MPEG-1 Layer II audio, live `.ts`). The previous engine is stopped first; one engine at a time.
- VLC capabilities shown honestly: no PiP, no AirPlay video (audio follows the route; the UI
  says to use Screen Mirroring), own controls (play/pause, seek, audio/subtitle tracks,
  in-app full screen). AVPlayer keeps AVKit UI, AirPlay video and PiP readiness.
- VLC errors carry no HTTP status/codec detail; they are reported as "cause unknown".

**LGPL-2.1 obligations — status**

| Obligation | Status |
|---|---|
| Tell users the app includes VLCKit and its license | Done: Settings → Open-source licenses, full LGPL text bundled |
| Point to the library's source | Done: link to code.videolan.org/videolan/VLCKit; exact version 3.7.4 |
| Allow replacing/relinking the library | Dynamic linking, unmodified. **Open for App Store**: App Store's signing model limits user relinking — get legal advice before release |
| Publish our modifications to VLCKit | None made |
| Codec patents (e.g. HEVC, AC-3, MPEG-2) | **Open**: legal review before distribution |
| Strip armv7/simulator slices for App Store | **Open** (release build step, Milestone 5) |

Distribution beyond the owner's own device is **blocked on the legal review** above.

### TV output for VLC content (2026-10-15)

AirPlay video (receiver fetches the URL) exists only for AVPlayer, and Apple TV cannot open MKV.
For VLC content the app uses the external-display scene that iOS provides during Screen
Mirroring (or HDMI): video is drawn full screen on the TV, controls stay on the phone, same
stream. Alternative considered and **not** taken: remuxing MKV on the device into HLS and
serving it from the phone to the TV over the LAN — that is a local stream proxy (ruled out
earlier), costs CPU/battery and would need an FFmpeg licensing review.

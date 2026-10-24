# Playback & HTTP compatibility matrix

Engine: **AVPlayer** (only engine in Milestone 1). Source: loopback fixture server.
Measured 2026-10-13 by `AVPlayerCompatibilityTests` (automated) and manual simulator runs.

**None of this is a physical-device or real-provider result.**

| Scenario (fixture) | macOS 27 AVFoundation | iOS 27 Simulator (iPhone 17) | App shows | Physical device |
|---|---|---|---|---|
| Live sliding-window HLS (`.m3u8`, TS segments, H.264/AAC) | Plays | Plays (also manually in-app, incl. channel switching) | Video | **Pending** |
| HLS playlist answered 404 | `NSURLError -1100` ← CoreMedia -12938 → `streamNotFound` | same | "Stream unavailable" | Pending |
| HLS playlist answered 403 | `NSURLError -1102` ← CoreMedia -12660 → `accessDenied(nil)` (status not reported by AVPlayer) | same | "The provider denied this stream" (no guessed cause) | Pending |
| Live raw MPEG-TS, no Content-Length / no ranges (`.ts` URL) | `AVError -11850` → `serverIncompatible` | same | "This stream type isn't supported by this player" | Pending |
| Finite raw TS file with Content-Length + byte ranges (`.ts` URL) | **Plays** | `AVError -11828` → `unsupportedFormat` | "This format isn't supported…" | Pending |
| TS body returned for a `.m3u8` request | CoreMedia -12646 → `unknown` | same (seen in app) | "Playback failed — cause not known" + code | Pending |
| HLS with undecodable segments | No error, never plays (waits forever) | same | Startup watchdog after 20 s → "The stream didn't start" | Pending |

Conclusions:

- HLS is the only reliably supported Xtream live output for the built-in engine. Prefer
  `m3u8` when `allowed_output_formats` includes it (or does not say).
- Typical Xtream `.ts` live output needs an alternate engine (ADR 0003).
- The 20 s startup watchdog is required; AVPlayer does not always fail on bad media.

## On-demand fixtures (Milestone 3) — AVPlayer

| Scenario | macOS 27 | iOS 27 Simulator (UI tests) |
|---|---|---|
| Progressive MP4 (H.264/AAC, byte ranges) | Plays; resume seek to 120 s exact; duration 180 s | Plays; resume offered after 36 s; continue watching works |
| MKV (H.264) | `unsupportedFormat` | "This format isn't supported by this player" |
| Movie without container in list or detail | — | "This title can't be opened" (address unknown, not guessed) |

Real provider (owner on iPhone 17 Pro, 2026-10-15): MP4 plays and resumes ("a bit slow");
MKV and most series episodes fail with "format not supported". Container mix measured by the
Debug probe (list endpoints only, no streams): movies mkv 14,508 · unknown 7,858 · mp4 2,115 ·
avi 138 · m3u8 7; episodes of the first 5 series: mkv 67/67. ⇒ AVPlayer can play roughly 9 %
of this source's movies and almost none of its series. Alternate engine decision: ADR 0003.

Resume speed change: the engine now defers `play()` until the resume seek finishes (no download
from 0 first) and seeks with 5 s keyframe tolerance instead of frame-exact. Device timing on the
real provider: **pending owner check**.

AirPlay on the real provider (owner): live channel failed during AirPlay with "access denied"
(receiver-side; HTTP status not reported by AVPlayer). Cause not determined; the receiver loads
the stream itself. Added "Play on this iPhone" (same session, local only). Needed: a redacted
diagnostics report from a failing AirPlay attempt.

## Real provider (Milestone 1.5, 2026-10-15) — iOS 27 Simulator, Debug build

Authorized Xtream provider; host and account deliberately not recorded.

| Check | Result |
|---|---|
| Auth (`player_api.php`) | OK — status active, expiry reported (mid-2027), max connections 2, formats `m3u8, ts, rtmp`, timezone Europe/Istanbul, not trial |
| Live categories | 35, 0 dropped |
| Live streams (one category) | loaded per category in the UI; probe sample 2 items, 0 dropped |
| VOD categories / streams | 118 / 24,626 (≈7.4 MB JSON, ≈1.4 s), 0 dropped |
| Series categories / series | 90 / 2,727 (≈2.2 MB JSON), 0 dropped |
| Live HLS playback (2 channels, one at a time) | **Fails**: media redirected to other HTTP hosts/IPs (ATS); with Debug arbitrary loads, audio is MPEG-1 Layer II → `'fmt?'` → "format not supported" |
| Channel switching / single session | One engine at a time; no provider TCP connections left open after closing the player |
| Relaunch | Source restored from Keychain; categories reloaded |
| Milestone 2 catalogue refresh (one request each: auth, categories, all live streams) | 35 categories, 1,373 channels, 0 dropped, saved in one transaction |

Nothing here was run on a physical device. The owner separately reports live TV working with
this source (see CLAUDE.md, "User-verified results"); Claude has not reproduced that.

## Player bugs (owner-reported 2026-10-15)

### 1. Full screen does not work

- **Root cause (reproduced):** `PlayerScreen` called `playback.stop()` and deactivated the audio
  session in `onDisappear`. AVKit's native full screen presents over the SwiftUI player, which
  fires `onDisappear`, so entering full screen ended the session (engine released, AVPlayer
  item removed). UI test before the fix: after full screen the session was `idle|none`.
- **Fix:** sessions end only when the player is closed (`fullScreenCover` onDismiss); audio
  session activated when playback starts and deactivated on close; the AVKit view stays
  mounted for the whole session (a retry no longer tears full screen down); AVKit's own
  full-screen control is used (same AVPlayer, `.resizeAspect`, no private API, no orientation
  hacks); in landscape on iPhone the channel bar is hidden to give the video more height.
- **Second cause found by the UI test:** AVKit itself pauses the player when full screen is
  closed with its Close button (iOS 27 simulator; same player identity, state `paused`). Fixed
  with the public `AVPlayerViewControllerDelegate` full-screen-end callback: if the stream was
  playing when closing began, the same AVPlayer resumes; a pause chosen inside full screen is kept.
- **Evidence (iPhone 18 Pro simulator, iOS 27, sample source):** `SeyrileoUITests` —
  full screen enter → app header not on top → rotate landscape/portrait → exit: same player
  identity, still `playing`; rotation + channel switch keeps one playing session; closing
  the player ends it. Before the fix the same test failed with `idle|none`, then (after the
  first fix) with `paused` — both reproduced, both fixed. Final run: 3/3 UI tests passed.
- **Device (owner-verified 2026-10-15, iPhone 17 Pro, real source):** passed.

### 2. AirPlay does not work

- **Code findings:** (a) the same `onDisappear` stop + audio-session deactivation could fire
  when a system presentation covers the player; (b) no AirPlay control outside AVKit's
  auto-hiding controls; (c) audio session had no long-form video route policy; (d) nothing
  showed whether a route was selected vs. actually playing. Which of these caused the owner's
  failure is **not proven** without a receiver.
- **Fix:** native `AVRoutePickerView` in the player header (video devices first); player sets
  `allowsExternalPlayback` and `usesExternalPlaybackWhileExternalScreenIsActive`; audio session
  `.playback` / `.moviePlayback` / `.longFormVideo`; `ExternalPlaybackMonitor` separates
  "device selected" (AirPlay output in route) from "playing on device"
  (`isExternalPlaybackActive`) and shows the device name; if the route disappears, playback
  resumes on the phone with the same player (no second AVPlayer, no new provider session).
  During AirPlay the receiver fetches the stream itself; failures then add an explicit note
  that the cause may be the receiver's network access, format support or redirects. The
  loopback sample source cannot be reached by a receiver and the UI says so. No proxy added.
- **Evidence:** UI test confirms the native picker is present and hittable in the player.
  Simulators have no AirPlay receivers.
- **Device (owner-verified 2026-10-15, iPhone 17 Pro, real source):** picker opens · device
  listed · selection · picture on TV · sound on TV · return to phone — all reported passed.
  Receiver model not recorded.

## TV output via Screen Mirroring (owner-verified 2026-10-15, iPhone 17 Pro, real source)

TV shows the video full screen through the app's external-display window. Not yet reported:
sound on the TV, VLC vs AVPlayer content tested, behaviour when mirroring stops.

## EPG (real provider, 2026-10-15, iPhone 17 Simulator)

| Endpoint / behaviour | Result |
|---|---|
| `get_short_epg` (limit 4) | OK: base64 titles, `start_timestamp`/`stop_timestamp` epoch; TRT 1, ATV, Show, Trt Spor correct now/next |
| `get_simple_data_table` | OK: ~9–13 days per channel (e.g. TRT 1: 256 programmes, 7–19 Oct), ≤4 MB cap |
| Channels with EPG id | 74 of 1,373 (5 %); rows without an id show the channel number only |
| Filler entries | Provider sends "No Data" placeholder programmes; dropped and counted |
| Time zone | Server `Europe/Istanbul`; times shown in device zone; manual ±12 h correction in Settings |

## Missing episode files (real provider, 2026-10-15)

Owner report: "Friends -Sıkı Dostlar" S01E02 failed (VLC error, then AVPlayer -11850 →
"serverIncompatible"). Measured with the Debug probe (first 16 bytes only, no playback):
the stream URL answers 302 to a storage host, which answers **200 text/html with an empty
body** for seasons 1–2 (S1E1, S1E2, S1E3, S2E1) whatever the User-Agent; S5E1 and S10E1 answer
206 `video/x-matroska` with the EBML signature and play in VLC (checked in the simulator).
Provider-side missing files. Fix: `MediaPreflight` (range 0–15) before movies/episodes; an
empty or HTML/JSON body now shows "The provider has no video for this title" instead of
trying both players. Errors/timeouts/non-2xx are left to the players.

## Lifecycle measurements (2026-10-17, iPhone 18 Pro simulator, sample source)

`SeyrileoUITests/LifecycleMeasurementTests` (XCTest metrics). Simulator numbers are not device
numbers, and the sample stream is a small test pattern — real HD streams cost more, especially in
VLC (software decoding since 2026-10-16). Re-run on a device with the command in the test file.

| Measurement | Result |
|---|---|
| Cold launch to first responsive frame (incl. XCTest attach, 3 runs) | 5.56 s average |
| Live HLS, built-in player, 20 s | memory 61 MB peak; CPU time 1.49 s (≈7 %) |
| Live HLS + MP2 audio, VLC (frame output, software decoding), 20 s | memory 78 MB peak; CPU time 1.65 s (≈8 %) |
| Background 8 s during playback, return | same session, playing — **failed before the fix**: AVPlayer paused in the background; fixed with `audiovisualBackgroundPlaybackPolicy = .continuesIfPossible` |

## Reminders (2026-10-17, iPhone 17 simulator, real source)

Reminder set on Trt Spor HD "Hafta Sonu Manşet" (09:30) at 09:03: permission prompt appeared on
the first reminder only; the system log shows delivery at 09:25:00 (5 minutes before).
Opening the channel from a reminder (cold start) checked with the DEBUG argument
`-SeyrileoOpenChannel`; tapping a real banner could not be automated in the simulator.

## HTTP / ATS

| Case | Result |
|---|---|
| Current config (Debug + Release) | `NSAllowsArbitraryLoads` only (ADR 0004) |
| `http://localhost:47816` (fixture) metadata + media | Works (verified in simulator after the ATS change) |
| Plain-HTTP remote provider, metadata | Works (real provider, catalogue refresh) |
| Plain-HTTP remote provider, media | Passes ATS. Earlier: per-domain exception and `NSAllowsArbitraryLoadsForMedia` both **ineffective** (media redirected to other hosts/IPs) |
| HTTPS remote provider | Expected to work — **not yet tested against a real host** |
| Cross-host / HTTPS→HTTP metadata redirect | Blocked (`unsafeRedirectBlocked`), unit-tested for the policy function only |

## Capability claims shown in Diagnostics

| Capability | AVPlayer status shown |
|---|---|
| HLS | Not verified (on device) |
| Live MPEG-TS (.ts) | Not supported |
| Picture in Picture | AVPlayer: AVKit button + automatic when leaving the app. VLC: frames delivered through libvlc video callbacks (NV12) into an AVSampleBufferDisplayLayer + AVPictureInPictureController (automatic start). The iOS 27 simulator reports PiP unsupported (`isPictureInPictureSupported() == false`), so PiP itself is **not verified**; in-app VLC picture via the new path is checked (aspect incl. non-square pixels). Device check pending owner. |
| AirPlay | Owner-verified on device with the real source (2026-10-15); Claude has not observed it |
| Audio & subtitle selection | Not verified |

## How to extend

Add a scenario to `FixtureServer.Channel` and a test in `AVPlayerCompatibilityTests`; run
`swift test --filter AVPlayerCompatibility` (macOS) and
`xcodebuild test -scheme SeyrileoKit-Package -destination 'platform=iOS Simulator,name=iPhone 17'`
from `Packages/SeyrileoKit`. Add a "Physical device" result only after running on hardware.

## External IDs in detail answers (real provider "ev", 2026-10-24)

Debug probe (`-SeyrileoProviderProbe`, `XtreamClient.probeDetail`), 6 films + 4 series, catalogue
requests only. Films (`get_vod_info`): no IMDb field; `tmdb_id` (numeric), `kinopoisk_url`,
`rating_count_kinopoisk`, `youtube_trailer`, `o_name`, `mpaa_rating`, `age`. Series
(`get_series_info`): no external ID at all. Mapping TMDb → IMDb would need the TMDb API
(an external metadata service, deferred in PRODUCT.md) — not done.
Owner decision (2026-10-25): no IMDb feature unless real IMDb ratings are available. They are
not available legitimately for this app (IMDb's official
API is a paid enterprise licence; its free datasets are non-commercial only; OMDb is
unofficial) — so IMDb is dropped. No TMDb/OMDb links, ratings or trailers added.

# Seyrileo — working notes

Native SwiftUI IPTV *player* for iPhone/iPad (Xtream-compatible sources the user is
authorized to use). Read [PRODUCT.md](PRODUCT.md) for boundaries, [ROADMAP.md](ROADMAP.md)
for milestones, [docs/REQUIREMENTS.md](docs/REQUIREMENTS.md) for per-requirement status.

## Layout

- `Seyrileo.xcodeproj` — app target, synchronized folder `Seyrileo/` (add files, no project edits).
- `Seyrileo/` — SwiftUI app (default MainActor isolation, Swift 6).
- `Packages/SeyrileoKit/` — `SeyrileoKit` (domain, Xtream adapter, networking, security,
  persistence, playback) and `SeyrileoFixtureServer` (loopback test provider + media).
- `Config/Info.plist` — merged into the generated plist; holds ATS settings only.
- `docs/adr/` — decisions; `docs/COMPATIBILITY.md`, `docs/RISKS.md`.
- `scripts/generate-fixture-media.sh` — regenerates synthetic fixture media (ffmpeg).
- `scripts/build-string-catalog.py` — regenerates `Seyrileo/Localizable.xcstrings` from
  compiler-extracted keys; fails on a missing Turkish translation.

## Commands

```bash
# Fast package tests (macOS)
cd Packages/SeyrileoKit && swift test

# Package tests on the iOS simulator (includes real AVPlayer matrix)
cd Packages/SeyrileoKit && xcodebuild test -scheme SeyrileoKit-Package -destination 'platform=iOS Simulator,name=iPhone 17' -derivedDataPath ../../build/PackageDerivedData

# UI tests (sample source only; use a simulator other than the one you are using by hand)
xcodebuild test -project Seyrileo.xcodeproj -scheme Seyrileo -only-testing:SeyrileoUITests -destination 'platform=iOS Simulator,name=iPhone 18 Pro' -derivedDataPath build/UITestDerivedData

# One-time: fetch the verified VLCKit binary (git-ignored Vendor/)
./scripts/fetch-vlckit.sh

# App build
xcodebuild -project Seyrileo.xcodeproj -scheme Seyrileo -destination 'platform=iOS Simulator,name=iPhone 17' -derivedDataPath build/DerivedData build

# After adding/changing user-facing strings: build, then
python3 -I scripts/build-string-catalog.py build/DerivedData   # add TR text to the script first
```

The app scheme's Test action runs the UI tests only; package tests use the package scheme above.
UI tests launch with `-SeyrileoFixturePort 47917` (DEBUG only) because simulators share the Mac's
network stack and two running apps would otherwise collide on the fixture port.

## Real provider check (never commit credentials)

```bash
cd Packages/SeyrileoKit && SEYRILEO_XTREAM_URL=… SEYRILEO_XTREAM_USER=… SEYRILEO_XTREAM_PASS=… swift test --filter RealProvider
```

Prints counts and account state only. Record results (redacted) in docs/COMPATIBILITY.md.

## Network / ATS

`Config/Info.plist` also declares `UIBackgroundModes: audio` (PiP + background sound).
For ATS it sets only `NSAllowsArbitraryLoads` — owner decision to
support plain-HTTP providers (ADR 0004). Do not add other ATS keys: they make iOS ignore it.
Never disable TLS validation; never downgrade an `https://` source. Enter credentials only in
the app's own setup screen. `-SeyrileoProviderProbe` (Debug launch argument) writes a redacted
list-endpoint summary to `Library/Caches/provider-probe.txt` without opening any stream.

## Data

Milestone 3 adds migration `v2-library` (movies, series, progress). Milestone 4 adds
`v3-organization`: `channelOverride` (alias, hidden), `channelAliasSearch` (FTS),
`channelOrder`, `categoryOverride`, `userCollection`, `collectionItem`. These are keyed by
source + provider ID (never by row) because catalogue refreshes delete and re-insert channels.
`LiveChannel.name` is always the provider's name; show `displayName`. EPG is never stored:
`EPGService` caches it in memory per source. `v4-parental` adds `lockedContent`; the PIN is in the
Keychain (`KeychainPINStore`, hash only). Parental enforcement lives in `AppModel.playbackItem`
(every route plays through it) — never open a stream for an entry without going through it. Movie/episode stream URLs
use the provider's container extension only (`ContainerExtension.sanitize`); never guess it.

On-device database: GRDB 7.11.1 (MIT), `Application Support/Catalog/catalog.sqlite`, schema in
`AppDatabase.migrator` (ADR 0002). New schema changes = new migration identifier, never edit
`v1-catalog`. Catalogue refreshes go through `CatalogStore.refresh` (download first, one write
transaction). User data (favorites, recents, preferences) lives in separate tables.

## Rules that are easy to break

- Never log/print a stream URL or `XtreamCredentials`; use `Redactor` / `Redactor.describe`.
- Never write catalogue rows outside `CatalogStore.apply`; never touch favorite/recent tables in a refresh.
- Search text goes through `SearchText.normalize` (Turkish İ/ı aware) on both sides.
- Identity = `MediaKey(providerID, kind, remoteID)`; never match by name.
- `PlaybackCoordinator` is the only owner of engines; never create an `AVPlayer` or `VLCMediaPlayer` elsewhere.
- VLC video goes through `VLCFrameOutput` (libvlc `video_set_callbacks`, resolved with dlsym; player
  handle via VLCKit 3's internal `-libVLCMediaPlayer`). If either is missing the engine falls back to
  VLC's own drawing (no PiP). Callbacks run on VLC's thread: keep that class `nonisolated`.
- Brand: colours `BrandNavy/Glow/Teal/Cream` and `BrandMark` (byte-identical copy of the owner's icon)
  in Assets; `LaunchMark` are rounded resized copies for the launch screen. Never alter the icon.
- VLCKit is LGPL: keep it unmodified and dynamically linked, keep Settings → Open-source licenses
  and the bundled license texts in `Seyrileo/Licenses/` in sync with the shipped version.
- Signing: Automatic, team `4GH66T5T9U` (owner's own Apple Development identity, needed to run on
  the owner's iPhone). Bundle ID `com.example.seyrileo` is still a placeholder for release.
- Never end the player session in a SwiftUI `onDisappear`: AVKit full screen and the AirPlay
  picker cover the view. The player is presented from the root (`AppModel.playerPresentation`);
  a session ends only on explicit close (`AppModel.playerDismissed` / `closeMiniPlayer`), never on
  minimize (mini player) or PiP.
- Every user-facing failure maps through `UserIssue`; say "unknown" when it is.
- Capability claims change only with evidence (update `EngineCapabilities` + COMPATIBILITY.md).
- No arbitrary sleeps in tests; inject `Sleeper` / use `AsyncGate`.
- Don't commit, push or publish without explicit instruction.

## User-verified results (reported by the owner; not reproduced by Claude)

- 2026-10-15 — The owner reports that live TV with their real Xtream source **works** on their
  side. Claude did not observe this: in Claude's own simulator runs that day, the two channels
  tried failed (ATS, then MP2 audio — see "Progress record"). Device/configuration used by the
  owner was not stated. Keep this separate from Claude's test results.

- 2026-10-15 — The owner reported two bugs while watching live TV: (1) full screen does not
  work, (2) AirPlay does not work. Fixes and evidence: docs/COMPATIBILITY.md, "Player bugs".
  AirPlay success on a physical iPhone + receiver is **not verified** by Claude.

- 2026-10-15 — App icon **chosen by the owner** (`Seyrileo-AppIcon-1024.png`). Used unchanged
  (byte-identical copy, SHA-256 `d966fd09…12b8ec5`): 1024×1024 PNG, 8-bit RGB, no alpha channel,
  no added corners, frame or padding. Single-size universal iOS entry in
  `Assets.xcassets/AppIcon.appiconset` (Xcode 14+ format); target uses
  `ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon`. Checks: Debug and Release builds without
  asset warnings, compiled `CFBundleIcons` present, icon visible on the iPhone 17 simulator home screen.

- 2026-10-15 — **Physical device, owner-verified:** Debug build installed by Claude on the owner's
  iPhone 17 Pro (iPhone18,1) via `devicectl`. The owner reports **all** requested checks passed
  with the real source: live TV, full screen (enter/rotate/exit, playback continues) and
  AirPlay (picker opens, TV listed, selection, picture and sound on TV, return to phone).
  Receiver model and per-step notes were not provided. Claude did not observe these runs.

- 2026-10-15 — **Owner-verified on iPhone 17 Pro:** Screen Mirroring works; the TV shows the
  video full screen (external-display window). Not reported: sound on TV, which content
  (VLC vs AVPlayer) was tested, return-to-phone behaviour.

- 2026-10-15 — **Owner-verified on iPad (iPad13,1, iPad Air 4th gen):** Debug build installed by
  Claude via `devicectl` (Developer Mode enabled by the owner). The owner reports "everything
  works" after testing on the iPad. Claude did not see which steps were run (requested: sidebar
  layout, live/full screen/rotation, guide, MKV in VLC, organization, Split View, mirroring).

## Progress record (Claude's own runs)

- 2026-10-13 — Milestones 0 and 1 complete for fixture + simulator. 71 package tests pass on
  macOS, 72 on the iOS 27 simulator (Keychain and real-provider tests skip there by design).
  Pending: real-provider validation, physical device checks, HTTP policy decision (ADR 0004),
  VLCKit decision (ADR 0003). Next: Milestone 2.
- 2026-10-15 — Milestone 1.5 (real provider, simulator): auth, live categories/channels, VOD and
  series lists work; live playback fails (media on other HTTP hosts → ATS; then MPEG-1 Layer II
  audio unsupported by AVPlayer). Debug-only, opt-in ATS config added; Release unchanged.
  Fixed: concurrent fixture-server start race, CoreMedia -1022 / 'fmt?' classification,
  misleading HLS suggestion. Next: owner decisions (ADR 0003 engine, ADR 0004 HTTP), then Milestone 2.
- 2026-10-15 — Milestone 2 (simulator): GRDB catalogue with transactional refresh, saved
  catalogue shown on launch with separate refresh status, FTS5 Turkish-aware debounced search
  with category filter, favorites (+ order) and recents, multi-source isolation, source removal
  cascade. HTTP sources enabled in Debug and Release (`NSAllowsArbitraryLoads` only). Tests:
  92 macOS / 93 iOS simulator, all passing (Keychain + real-provider suites skip by design).
  Real provider: one catalogue refresh (35 categories, 1,373 channels), no streams opened.
  Next: Milestone 3 (movies/series + resume).
- 2026-10-15 — Player bugs (owner-reported): full screen and AirPlay. Root cause for both
  candidates: `PlayerScreen.onDisappear` stopped the session and deactivated the audio session
  whenever AVKit's full screen (or another presentation) covered the player. Fixed; native
  AVRoutePickerView + external-playback monitor added. Second cause: AVKit pauses on its
  full-screen Close button; resumed via AVPlayerViewControllerDelegate. UI tests (iPhone 18 Pro
  sim) failed before each fix and pass after (3/3). Package tests 93/93. Also fixed a flaky
  `ProviderSource` date-precision equality. AirPlay to a real receiver: pending owner device test.
- 2026-10-15 — Milestone 3 (fixture + simulator): movies/series catalogue (GRDB v2), detail
  endpoints, movie/episode playback, resume/progress, continue watching, next episode,
  movie/series search with category filter, bounded poster loader. Fixed before merge: live
  refresh would have wiped the movie/series search index (shared delete helper) — split and
  tested. Tests: 116 package (macOS), 6/6 UI tests (iPhone 18 Pro sim). Real provider: pending.
- 2026-10-15 — Owner feedback on Milestone 3 (device): MKV/series fail (format), MP4 resume
  slow, AirPlay often "access denied". Measured container mix (59 % mkv, 32 % unknown, 9 % mp4;
  episodes all mkv). Fixed: deferred-play + tolerant resume seek; "Play on this iPhone" fallback;
  movie/episode-specific format message. Alternate engine still an open owner decision (ADR 0003).
- 2026-10-15 — Owner chose VLCKit (option A). MobileVLCKit 3.7.4 (official VideoLAN binary,
  SHA-256 verified) embedded; `VLCEngine` with own controls; mkv/avi start in VLC, AVPlayer
  format failures fall back once to VLC. LGPL notice + license texts in Settings. Distribution
  beyond the owner's device blocked on legal review (ADR 0003).
- 2026-10-15 — VLC verification (iPhone 18 Pro sim): 7/7 UI tests pass, incl. MKV in VLC and
  live HLS with MP2 audio falling back AVPlayer → VLC in one session (new fixture channel 205,
  reproduces the owner's 'fmt?' on iOS; macOS AVPlayer can decode MP2). Package tests 121 macOS /
  122 iOS. Build installed on the owner's iPhone; device results pending owner.
- 2026-10-15 — Owner rejected "VLC sends only audio over AirPlay". Added external-display output:
  AppDelegate supplies an external-display scene; while Screen Mirroring/HDMI is active, VLC
  renders into a full-screen TV window (same player/stream, `VLCEngine.render(into:)`), phone
  keeps controls. VLC titles show a "Watch on TV" button with mirroring steps instead of the
  audio-only route picker. AVPlayer content keeps AirPlay video. Not verifiable in the simulator
  via CLI; device check pending owner. True AirPlay video for MKV would need on-device remux +
  local HTTP serving to the TV (a proxy, previously ruled out) — not done.
- 2026-10-15 — Owner screenshot: live HLS over AirPlay video → "access denied" (receiver fetch).
  Change: during Screen Mirroring, AVPlayer no longer hands off to the receiver
  (`usesExternalPlaybackWhileExternalScreenIsActive = false`, external playback off while an
  external display is connected); the phone-decoded picture is drawn on the TV window via a
  second AVPlayerLayer. Error card offers "Watch on TV with Screen Mirroring". Package tests 121
  pass; last full UI run (7/7) predates this final change. Device check pending owner.
- 2026-10-15 — Milestone 4 part 1, EPG (real provider "ev" in the iPhone 17 sim, one stream at
  a time): now/next on rows, guide overview, per-channel day guide, "Now:" in the player.
  Real data: 74/1,373 channels have EPG ids; day tables span ~9–13 days. Fixed against real
  data: provider "No Data" filler shown as programmes; day guide opened on the oldest day with
  staggered rows (TimelineView wrapped the List's ForEach). Package tests 131; UI 7/7.
- 2026-10-15 — Milestone 4 part 2, organization: alias, hide, personal order (channels per
  category, categories), collections (channels, films, series) with migration v3. Rename and
  "new collection" use a sheet (an alert text field did not save reliably under UI automation).
  Package tests 140 (macOS). Free-tier collection limit not enforced until StoreKit (M5).
- 2026-10-15 — Owner screenshot: Friends S01E02 "serverIncompatible". Root cause measured: the
  provider returns an empty HTML page (302 → 200, 0 bytes) for seasons 1–2; S5/S10 are real MKV
  and play in VLC. Added `MediaPreflight` (16-byte range check) and a specific message. Debug-only
  helpers: `-SeyrileoMediaProbe <series>` (probe extension), `-SeyrileoDebugSeriesSearch <text>`.
  Package tests 143; UI tests 10/10 (iPhone 18 Pro sim).
- 2026-10-15 — Milestone 4 part 3, parental controls: PIN (PBKDF2, Keychain), lockout,
  category/item locks (v4), single playback gate, masking, unlock guard, relock on background,
  Face ID/Touch ID (biometrics only). DEBUG `-SeyrileoResetParental` clears the PIN for UI
  tests. Package tests 150; parental UI test passes (create PIN → lock category → masked in
  Live and Search → wrong PIN refused, no playback → right PIN unlocks → cleanup).
- 2026-10-16 — Owner request: PiP + keep playing while browsing. Player now presented from the
  root; "Minimize" shows a draggable mini player over the tabs (same engine/stream). PiP enabled
  for AVPlayer (AVKit button + automatic on leaving the app, also from the mini player layer);
  `UIBackgroundModes: audio`. VLC content: no system PiP (MobileVLCKit 3.x), mini player and
  background sound only. UI tests 12/12 (new: minimize → browse tabs → expand, same player).
  PiP itself is not verifiable via simulator automation; device check pending owner.
- 2026-10-16 — Owner: PiP when leaving the app + use the icon in the app. Measured: iOS 27
  simulator reports PiP unsupported (AVKit shows no PiP button), so PiP cannot be observed there.
  Added PiP for VLC content (frame output → sample-buffer layer → AVPictureInPictureController);
  fixed a crash (MainActor-isolated C callbacks) and non-square-pixel aspect. Brand: icon-derived
  palette, launch screen, redesigned welcome, Your Space greeting card, Settings about card.
- 2026-10-16 — Owner: series opened with English audio + Turkish subtitles came back with Turkish
  audio and no subtitles on "Continue". Added `TrackPreference` (by track name, language fallback;
  stored per series/movie/channel in `sourcePreference`), applied by VLCEngine when tracks appear.
  Found and fixed while testing with the real source: the VLC controls' TimelineView rebuilt the
  track Menu every 0.5 s (menu closed itself), auto-hide removed an open menu, and two Pickers in
  one Menu with overlapping track numbers routed taps to the wrong picker (now plain buttons).
  Verified in the sim with the real source: choose English + Türkçe → close → "Continue" and next
  episode both open English + Türkçe; subtitles render in the frame-output path. Paw-print loader.
  Package tests 155. AVPlayer (MP4) track memory not done yet.
- 2026-10-16 — Owner (device): subtitles not shown. Likely cause: frame-output mode + VideoToolbox
  (GPU pictures; VLC does not blend subtitles into the callback frames; in the simulator VT fails
  and software decoding showed them). Frame-output mode now forces software decoding
  (`:codec=avcodec`, `:avcodec-hw=none`). Sim re-checked; device result pending owner. Cost: more CPU.

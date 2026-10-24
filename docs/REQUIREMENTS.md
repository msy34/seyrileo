# Requirement checklist

Status values: **tested** (automated test exists and passes) · **sim-checked** (manually
verified in iOS Simulator) · **implemented** (code exists, not specifically verified) ·
**partial** · **not started**. "Device" and "real provider" are always separate columns.

Last updated: 2026-10-15 (end of Milestone 2).

## Milestone 1 vertical slice

| Requirement | Status | Real provider | Device |
|---|---|---|---|
| Source setup: name, URL, username, password, show/hide | sim-checked | pending | pending |
| Server address normalization, HTTPS default, pasted `get.php` link split | tested | pending | — |
| Connection test with actionable errors before saving | implemented (errors tested at adapter level) | pending | pending |
| Xtream auth (`player_api.php`), account state advisory, `auth:0` rejection | tested (stub + loopback) | **pending** | — |
| Live categories → per-category channels (progressive) | tested + sim-checked | **pending** | pending |
| Local channel filter within category | implemented | — | — |
| Playback of supported stream (live HLS) | tested (AVPlayer, macOS + iOS sim) + sim-checked | **pending** | **pending** |
| Single active session; stop before next; stale events ignored | tested (100 switches) + sim-checked | pending | pending |
| Bounded retries, no retry for auth/404/ATS/format | tested | — | — |
| Startup watchdog for silent engines | tested | — | pending |
| Evidence-based error messages (no 403→"connection limit" guess) | tested (classification) + sim-checked (one case) | pending | — |
| Credentials only in Keychain; config JSON without secrets | tested (registry) + sim-checked (container grep, relaunch) | — | pending |
| Persistence across relaunch | sim-checked | — | pending |
| Redaction (URLs incl. path, reserved chars, NSError, logs, report) | tested | — | — |
| Diagnostics sheet + redacted share | sim-checked (view); share sheet not exercised | — | — |
| Remove source / remove all data (Keychain + JSON) | tested (registry); UI implemented | — | — |
| Fixture mode clearly labeled | sim-checked | n/a | — |
| TR/EN String Catalog (214 keys, generated + checked) | sim-checked (TR) | — | — |
| Dark/light, Dynamic Type, VoiceOver labels | implemented; dark/light sim-checked partly; VoiceOver/Dynamic Type **not audited** | — | pending |
| iPad sidebar layout | implemented (`.sidebarAdaptable`); not run on iPad sim | — | owner-verified (iPad Air 4, 2026-10-15: "everything works") |
| Playback/HTTP compatibility matrix | done for fixture (docs/COMPATIBILITY.md) | **pending** | **pending** |

## Milestone 1.5 — real provider (2026-10-15, iOS 27 Simulator / iPhone 17)

| Check | Status |
|---|---|
| Source added through the real setup UI (user typed credentials) | done |
| Auth + advisory account state | verified with real provider |
| Live categories + per-category channels | verified with real provider |
| VOD / series list endpoints (probe only, no screens) | verified with real provider |
| Live playback | **failing** — ATS (media on other hosts) then MP2 audio unsupported by AVPlayer |
| Error classification for the observed failures | tested (unit) + sim-checked |
| Relaunch restores source from Keychain | verified (simulator) |
| No credentials in app files, repo or reports | checked (structure + grep for host; credentials never typed in commands) |
| Physical device | **pending** |

## Milestone 2 — local catalogue (2026-10-15, iOS 27 Simulator / iPhone 17)

| Requirement | Status | Real provider | Device |
|---|---|---|---|
| GRDB integrated, version + license verified (7.11.1, MIT) | done | — | — |
| Sources, categories, channels persisted | tested + sim-checked | verified (1 refresh: 35 / 1,373) | pending |
| DB work off the main thread (detached open/migrate, async reads/writes) | implemented; not profiled | — | pending |
| Saved catalogue shown immediately; refresh status shown separately | sim-checked | verified | pending |
| Refresh applied in one transaction | tested | verified | — |
| Failed / cancelled refresh keeps catalogue | tested | — | — |
| Favorites, personal order, preferences, recents survive refresh | tested | — | — |
| Removed provider items stay as "no longer offered" favorites | tested; UI implemented | — | — |
| Source removal deletes catalogue, favorites, recents, preferences, search rows, Keychain item | tested | — | — |
| Indexed (FTS5), debounced search | tested + sim-checked | verified (local DB query) | pending |
| Turkish characters / case (İ ı I i, ç ğ ö ş ü) | tested (25 cases) | spot-checked on real names | — |
| Category filter + clear empty state | implemented; UI partly sim-checked | — | — |
| Favorite add/remove (list swipe, context menu, player) and play from favorites | sim-checked (add from list and player) | add only | pending |
| Recents recorded only on actual playback start | tested + sim-checked (fixture) | — | — |
| Favorites/recents persist across relaunch | sim-checked | — | pending |
| Multi-source isolation (same provider IDs in two sources) | tested + sim-checked | — | — |
| One active playback session kept | tested (existing suite) | — | pending |
| Migration from Milestone 1 JSON | tested + sim-checked (in-place upgrade) | — | — |
| Plain-HTTP sources in Debug + Release; HTTP notice in setup | implemented; Release plist checked | metadata verified | pending |
| Pro / StoreKit | not started (M5) | — | — |

## Player fixes (2026-10-15)

| Requirement | Status | Device |
|---|---|---|
| Full screen keeps the same AVPlayer/session; exit does not stop playback | UI-tested (simulator) | owner-verified |
| Rotation, channel switch, close ends session | UI-tested (simulator) | owner-verified |
| Native AirPlay picker in player | UI-tested (present, hittable) | owner-verified |
| AirPlay states: selected / playing on device / returned to phone | implemented | owner-verified |

## Milestone 3 — movies, series, progress (2026-10-15, fixture + iOS 27 Simulator)

| Requirement | Status | Real provider | Device |
|---|---|---|---|
| VOD/series categories + lists stored (one transaction, failure/cancel safe) | tested | pending | pending |
| Movie detail (`get_vod_info`), series detail (`get_series_info`) incl. `info: []`, keyed/nested episodes | tested | pending | — |
| Container from list or detail; unknown container → explicit error, never guessed | tested + UI-tested | pending | — |
| Movie/episode playback (progressive MP4, byte ranges) | tested (AVPlayer, macOS) + UI-tested | pending | pending |
| MKV → "format not supported" (AVPlayer) | tested + UI-tested | pending | pending |
| Resume at saved position; retry continues from last position | tested (AVPlayer seek + coordinator) + UI-tested | pending | pending |
| Progress saved periodically, on switch and on close; live never saved | tested | — | pending |
| Completion rule (≥95 % or ≤90 s left), resume threshold 30 s | tested | — | — |
| Continue watching (one entry per series, newest first, removable) | tested + UI-tested | pending | pending |
| Series: seasons, episodes, watched marks, progress bars, continue/next episode | UI-tested (next episode) | pending | pending |
| One active stream while switching episodes | UI-tested (player identity changes, single session) | — | pending |
| Movie/series search (FTS, Turkish-aware) + category filter | tested; UI implemented | pending | — |
| Library isolation per source; removal deletes library + progress | tested | — | — |
| Migration v1 → v2 keeps existing data | tested | — | — |
| No TMDb, recommendations or catch-up | respected | — | — |

## Milestone 4 — EPG and personal organization (2026-10-15, real provider + iOS 27 Simulator)

| Requirement | Status | Real provider | Device |
|---|---|---|---|
| Now/next on channel rows (lazy per visible row, ≤3 concurrent, 15 min cache, failures cached 5 min) | tested + checked | checked (TRT 1, ATV, Show, Trt Spor) | pending |
| Base64 titles, epoch times, server-zone local times across DST, manual ±12 h correction | tested | checked (Europe/Istanbul) | — |
| Provider filler entries ("No Data") dropped, not shown as programmes | tested | checked | — |
| Guide overview (channels with guide ids) + per-channel day guide (opens on today, scrolls to on-air) | sim-checked | checked (7–19 Oct table) | pending |
| Player header "Now: …" for live channels | sim-checked | checked (one stream, closed after) | pending |
| XMLTV import | not started (deferred; Xtream EPG only) | — | — |
| Local channel alias (provider name kept and shown; alias searchable, Turkish-aware) | tested + UI-tested | — | pending |
| Hide channels/categories (left out of lists, search, guide, channel switching; restorable) | tested + UI-tested | — | pending |
| Personal channel order per category and category order (survive refresh; new channels last; reset) | tested | — | pending |
| Collections of channels, films, series (create, rename, reorder, delete; unavailable items kept) | tested + UI-tested | — | pending |
| Organization survives catalogue refresh; removed with the source; migration v3 | tested | — | — |
| Free-tier collection limit (1) | enforced (M5), UI-tested | — | pending |
| Mini player while browsing (minimize, drag to corners, expand, close; same session) | UI-tested | — | pending |
| Picture in Picture (AVPlayer: AVKit; VLC: frame output + sample-buffer PiP; automatic when leaving the app) | implemented; sim has no PiP support | — | pending |
| Remember audio/subtitle choice per series/movie (name, then language match); applied on Continue and next episode (VLC) | tested + sim-checked (real source) | checked | pending |
| Languages EN (default), TR, FR, AR (RTL), RU, DE, BS with flag picker; live switch | sim-checked (EN/FR/DE/AR) | — | pending |
| Reminders: bell on upcoming programmes; notification 5 min before; permission asked on first reminder | sim-checked (real source, delivery logged) | checked | pending |
| Reminders: locked channels masked in notifications; tap opens channel through the parental gate; max 60; ended pruned; removed with source | tested + sim-checked (open path via DEBUG arg) | — | pending |
| Lifecycle: background during playback keeps the session (fixed); launch/memory/CPU measured (sim) | UI-tested + measured | — | pending |
| Remembered audio/subtitles also in the built-in player (MP4): applied on load, AVKit menu changes saved | tested (fixture MP4 with EN/TR audio + subtitles, macOS AVFoundation) | — | pending |
| Seyrileo Pro paywall, purchase, restore; DEBUG unlock, `-SeyrileoFreeTier` | UI-tested (paywall + free limits) | — | pending |
| Privacy manifest; Release build; accessibility audit (6 screens) | done / built / 44→39 findings | — | — |
| Brand: icon used in launch screen, welcome, Your Space, Settings; icon-derived palette | sim-checked | — | pending |
| Parental PIN (4–6 digits; PBKDF2-SHA256 + salt in Keychain, this device only) | tested | — | pending |
| Wrong-PIN lockout (5 free, then 30 s doubling to 15 min; survives restart) | tested | — | pending |
| Lock live/movie/series categories and single channels/films/series | tested + UI-tested (category) | — | pending |
| Enforcement: one gate for every playback route (lists, search, Your Space, recents, collections, guide, in-player switching) | UI-tested (search + category) | — | pending |
| Locked content masked in lists/search/Your Space; removed from guide; locked screens show an unlock prompt | UI-tested (category, search) | — | pending |
| Relock when the app goes to the background; Face ID/Touch ID unlock (biometrics only, not passcode) | implemented; biometrics not testable in sim | — | pending |

## Full v1 contract

| # | Item | Status |
|---|---|---|
| 1 | Xtream source setup + secure storage | done for M1 (see above) |
| 2 | Live categories, channels, local search, now/next, favorites, recents, collections | done (simulator; device pending) |
| 3 | VOD movies + progress | done (fixture/simulator; real provider pending) |
| 4 | Series, seasons, episodes, progress, next episode | done (fixture/simulator; real provider pending) |
| 5 | EPG guide, TZ/DST, XMLTV | Xtream EPG done (real provider checked in simulator); XMLTV not started |
| 6 | Multiple sources, isolation, namespaced IDs, one active session | done (free-tier limit not enforced until M5) |
| 7 | Collections, aliases, hide/reorder | done (simulator; free-tier limit in M5) |
| 8 | Parental PIN/biometrics on all routes | done (simulator); device + Face ID pending; reminders/deep links will reuse the same gate |
| 9 | Audio/subtitle selection, PiP, AirPlay where verified | partial: AVKit native menus/route button present, all unverified; PiP not enabled |
| 10 | Diagnostics, bounded retries, redacted export, data deletion, cache mgmt, a11y, languages | done in simulator; automated a11y audit run (see docs/RELEASE.md); 7 languages |
| 11 | Local EPG reminders | done (simulator, real source); device pending |
| 12 | StoreKit 2 Pro | implemented (M5): non-consumable, free limits enforced in Release; real product + sandbox purchase pending owner (docs/RELEASE.md) |

# ADR 0002 — Persistence and credentials

Status: accepted (Milestone 1 credentials; Milestone 2 on-device database)

## Decision

- **Credentials** (username + password) live only in the Keychain:
  generic password, service `provider-credentials.v1`, account = source UUID,
  `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, data-protection keychain on iOS.
  - *AfterFirstUnlock* allows a future best-effort background refresh.
  - *ThisDeviceOnly* keeps credentials out of backups and device migration (users re-enter
    them on a new device — acceptable, and safer).
- **Source configuration** lives in the on-device database (below) since Milestone 2. The
  Milestone 1 JSON file `Application Support/Sources/sources.json` is imported once at launch
  (idempotent) and renamed to `sources.json.imported`; it never contained secrets.
- `SourceRegistry` writes credentials first and rolls them back if the config write fails;
  removal deletes both; orphaned Keychain items are pruned at launch (Keychain survives app
  deletion on iOS).
- UserDefaults holds only the active source UUID.
- Metadata networking uses an **ephemeral** URLSession (no disk cache, cookies or credential
  storage) so secret-bearing request URLs are never persisted.

## On-device database (Milestone 2)

- **GRDB 7.11.1**, pinned `exact:` in `Packages/SeyrileoKit/Package.swift` (resolved revision
  `b83108d1…`, tagged 2026-06-18). License **MIT** (verified from the tagged repository's
  LICENSE). GRDB ships its own `PrivacyInfo.xcprivacy` declaring no tracking, no collected data
  and no required-reason APIs. Uses the system SQLite.
- File: `Application Support/Catalog/catalog.sqlite` (brand-neutral), `DatabasePool` (WAL), foreign
  keys on. All reads/writes are `async` and run on GRDB's queues; opening and migrating happens
  in a detached task at launch, so the main thread is never blocked.
- Schema `v1-catalog` (`AppDatabase.migrator`): `source`, `catalogState`, `liveCategory`,
  `liveChannel`, `liveChannelCategory`, FTS5 `liveChannelSearch`, `favorite`, `recent`,
  `sourcePreference`. Every row is keyed by **source UUID** (+ kind + provider ID for user data =
  `MediaKey`). Deleting a `source` row cascades to everything it owns; FTS rows are deleted
  explicitly in the same transaction.
- **Refresh** (`CatalogStore.refresh`): download auth + categories + all live streams first,
  then replace that source's catalogue rows in **one write transaction**. A thrown error records
  `lastErrorCode` only; cancellation records nothing; a crash rolls back. Favorites, recents and
  preferences are separate tables and are never touched by a refresh. Items the provider
  removes stay favorited but show as "no longer offered"; they reattach only by the same
  provider ID, never by name.
- **Search**: names are normalized (`SearchText`: case-, diacritic- and Turkish-İ/ı-insensitive,
  punctuation → spaces) into `searchName` and indexed with FTS5 `unicode61`; queries are
  word-prefix matches, debounced 250 ms (`ChannelSearchController`).
- Catalogue is refreshed automatically when older than 6 h, on demand (pull to refresh /
  Settings), and the saved catalogue is always shown first.

## Library and progress (Milestone 3, migration `v2-library`)

- Tables `mediaCategory`, `movie`, `series`, `mediaMembership`, FTS5 `mediaSearch`,
  `libraryState`, `playbackProgress`; all keyed by source UUID, cascade on source removal.
- Library refresh: VOD categories, all VOD, series categories, all series (4 requests) when
  the Library is first used and when older than 12 h; one write transaction; deletes only the
  library's own rows and index (live refresh likewise touches only the live index — tested).
- Detail endpoints are not stored; they are cached in memory for the session.
- Progress: periodic (5 s) + on switch/close; `completed` at ≥95 % or ≤90 s left; resume only
  from ≥30 s; unknown duration never counts as completed.

## Verified

- Unit tests: round trip, no secrets in the JSON file, rollback, prune, newer-schema refusal.
- Milestone 2 tests: migration applied once + reopen, legacy JSON import (idempotent), refresh
  success/failure/cancellation, favorites/order/preferences/recents survive refresh, source
  removal deletes all owned rows + Keychain item, cross-source isolation, Turkish search.
- Simulator: Milestone 1 data migrated in place (2 sources imported, JSON renamed); real
  provider catalogue saved (35 categories, 1,373 live channels) with one refresh; favorites and
  recents survived an app relaunch.
- Simulator: after relaunch the source reloads and authenticates from the Keychain; the app
  container contains no username or password (checked with `grep`).
- Keychain unit test runs only in a host with a keychain entitlement; SwiftPM's simulator
  test host has none (-34018), so the app-level relaunch check is the evidence.

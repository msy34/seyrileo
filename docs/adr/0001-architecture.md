# ADR 0001 — Architecture and module layout

Status: accepted (Milestone 1)

## Decision

- **App target `Seyrileo`** (SwiftUI, iOS 17+, Swift 6, default MainActor isolation):
  feature folders `App`, `Onboarding`, `SourceSetup`, `Live`, `Player`, `Settings`,
  `Shared`. Views and view models only.
- **Local Swift package `Packages/SeyrileoKit`** (iOS 17 / macOS 14, Swift 6 language mode):
  - `SeyrileoKit` — UI-free domain models, Xtream provider adapter, networking, security
    (redaction, Keychain), persistence and the playback coordinator/engine protocol.
  - `SeyrileoFixtureServer` — loopback fixture provider and generated media (ADR 0005).
- Xcode project is hand-maintained with **synchronized folders** (objectVersion 77), so new
  files in `Seyrileo/` need no project edits.
- No third-party dependencies in Milestone 1.

## Rules

- Provider DTOs never leave `Xtream/`; UI sees `ProviderSource`, `LiveCategory`,
  `LiveChannel`, `AccountInfo`, `PlaybackItem`.
- Identity is `MediaKey(providerID, kind, remoteID)` — never names.
- Dependencies are passed explicitly (`AppModel.live()` composes them); no service locator.
- The package builds on macOS so `swift test` runs in seconds; iOS-specific code is guarded.
- A future tvOS target reuses `SeyrileoKit`; no tvOS UI now.

## Consequences

Fast, deterministic tests for adapter, redaction, retry and playback ownership. The app layer
is thin but currently untested by UI tests (manual simulator checks only — see
REQUIREMENTS.md).

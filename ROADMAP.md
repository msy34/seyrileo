# Roadmap

| Milestone | Scope | Status |
|---|---|---|
| 0 | Repository inspection, product contract, ADRs, risk list, requirement checklist | **Done** (2026-10-13) |
| 1 | Vertical slice: source setup → Xtream auth → live catalogue → playback → secure persistence → bounded errors; labeled fixture mode; compatibility matrix | **Done** (simulator); real provider checked in 1.5 |
| 1.5 | Real-provider check: auth, catalogue, VOD/series list endpoints, ATS diagnosis | **Done** (2026-10-15) |
| 2 | Transactional local catalogue (GRDB), categories, indexed local search, favorites, recents, multi-source isolation, migration tests; HTTP sources supported | **Done** (2026-10-15, simulator) |
| 3 | Movies, series, episodes, detail endpoints, persisted progress, continue watching | **Done** (2026-10-15, fixture + simulator); real provider **pending** |
| 4 | EPG + timezone/DST, collections, alias/hide/reorder, parental locks, reminders, device lifecycle measurements | **Done (simulator)**: EPG, organization, parental controls, reminders, lifecycle measurements; owner device checks pending |
| 5 | StoreKit 2 Pro, release docs, privacy/attribution review, TestFlight checklist, owner blockers | **Code done (simulator)**; blocked on owner items in docs/RELEASE.md |

## Next step (Milestone 4)

Done: Xtream EPG (now/next, guide, DST, manual correction) and personal organization (alias,
hide, order, collections). Parental PIN/biometric locks are done and enforced through the single playback gate. Next:
(done) local EPG reminders
(notification permission asked only when the first reminder is set), then device lifecycle
measurements. Owner device checks of EPG/organization pending.

## Later decisions tracked here

- Alternate engine (VLCKit) — ADR 0003; needed for live MPEG-TS.
- PiP/background audio mode — enable only with device verification (Milestone 4).
- Fixture server in release builds — ADR 0005.

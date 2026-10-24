# Release and TestFlight checklist (Milestone 5)

Status 2026-10-17. Nothing here has been submitted. Items marked **owner** need decisions or
accounts only the owner has; Claude cannot create them.

## Done in the code

| Item | Where | Verified |
|---|---|---|
| Seyrileo Pro: one non-consumable, StoreKit 2, verified entitlements, `Transaction.updates`, restore (`AppStore.sync`) | `Seyrileo/Pro/ProStore.swift` | build + UI test (paywall, free limits); no real purchase yet |
| Free tier: 1 provider source (sample not counted), 1 collection; Pro: more sources, unlimited collections, rename/hide/reorder, reminders | `ProPolicy` (package, tested) + gates in the app | `ProUITests` |
| Losing Pro removes nothing (existing collections, names, hidden items, reminders keep working; un-hiding and removing a reminder stay free) | gates only on *new* Pro actions | code review |
| DEBUG builds unlock Pro (owner device testing); `-SeyrileoFreeTier` tests the free tier | `ProStore.init` | Release binary contains no DEBUG launch-argument strings (checked with `strings`) |
| StoreKit test file for running from Xcode | `Config/Seyrileo.storekit`, scheme Run + Test | not applied by `xcodebuild` / `simctl`; open in Xcode to test buying |
| Privacy manifest: no tracking, no collected data, UserDefaults reason CA92.1 | `Seyrileo/PrivacyInfo.xcprivacy` | present in the Release bundle; GRDB ships its own |
| Release configuration builds for devices | `xcodebuild -configuration Release` | 2026-10-17 |
| Accessibility audit on 6 main screens | `SeyrileoUITests/AccessibilityAuditTests` | findings 44 → 39; see below |
| 7 languages, string catalog check | `scripts/build-string-catalog.py` | 485 keys × 7 languages |
| Data deletion, redacted diagnostics export, licenses screen | Settings | earlier milestones |

## Owner blockers (App Store Connect)

1. **Bundle ID** — `com.example.seyrileo` is a placeholder. Choose the real ID; change
   `PRODUCT_BUNDLE_IDENTIFIER` (Debug + Release) and the Keychain stays per bundle ID (existing
   test installs will need their sources re-added).
2. **Pro product** — create a non-consumable in App Store Connect and tell Claude its ID;
   replace `ProStore.productID` and `Config/Seyrileo.storekit`. Price comes only from the store.
3. **Agreements** — Paid Applications agreement, tax and banking, or the product never loads.
4. **Privacy policy URL** and **support URL** (required on the App Store page). Suggested
   content: everything stays on the device; the app does not collect data; diagnostics are shared
   only by the user.
5. **App Privacy answers** in App Store Connect: "Data Not Collected".
6. **App Review account** — a working, authorized Xtream test account for the reviewer and notes
   that Seyrileo is a player without content (review guideline 5.2.3 risk; see docs/RISKS.md).
7. **Rights / trademark** checks for the name and icon.
8. **VLCKit (LGPL-2.1) legal review** before distribution (ADR 0003). Open item:
   MobileVLCKit includes 32-bit slices (armv7/armv7s) that iOS 17 cannot use; an arm64-only
   copy is 38 MB instead of 101 MB (app 124 MB → about 61 MB). Removing architectures with
   `lipo` does not change the code, but confirm it fits the "unmodified" LGPL notice first.
9. **Export compliance** — the app uses only Apple's HTTPS/TLS (standard exemption); answer
   accordingly when uploading.

## TestFlight steps (after the blockers)

1. Set the real bundle ID and product ID; run package + UI tests.
2. `xcodebuild archive -project Seyrileo.xcodeproj -scheme Seyrileo -configuration Release -archivePath build/Seyrileo.xcarchive`
3. Upload from Xcode Organizer (or `xcodebuild -exportArchive` with an App Store export plist).
4. Internal testers first; check: purchase + restore in the sandbox, PiP and AirPlay on device,
   reminders, parental PIN with Face ID, all 7 languages, iPad layout.

## Accessibility audit — remaining findings (2026-10-17)

Fixed: channel/poster initials did not scale with Dynamic Type; low-contrast version label.
Remaining are mostly "contrast nearly passed" for system secondary text, rows measured under the
floating tab bar (scroll position), and "text clipped" on single-line titles that intentionally
truncate. Re-check on a device with large accessibility text sizes.

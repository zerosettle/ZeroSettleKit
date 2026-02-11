# CLAUDE.md - ZeroSettleKit (Source SDK)

## Overview
`ZeroSettleKit` is the native iOS/Swift SDK — the **source framework** that all platform wrappers depend on. It provides the public API for configuration, product catalog, payment sheet presentation, entitlement management, and subscription lifecycle.

## Key Files
* `Sources/ZeroSettleKit/ZeroSettle.swift` — Singleton entry point (`ZeroSettle.shared`), all public methods
* `Sources/ZeroSettleKit/UI/ZSPaymentSheet.swift` — Payment sheet UI + `present(from:)` UIKit bridge
* `Sources/ZeroSettleKit/ZeroSettleDelegate.swift` — Delegate protocol for checkout/entitlement events
* `Sources/ZeroSettleKit/Models/` — All public model types (`ZSProduct`, `Price`, `Entitlement`, `ZSTransaction`, etc.)
* `ZeroSettleKit.podspec` — CocoaPods spec (current version: see `s.version`)

## Concurrency
* `ZeroSettle.shared` is `@MainActor`-isolated. All callers from non-main-actor contexts (e.g., Flutter/RN bridge `handle()` methods) must dispatch via `Task { @MainActor in }`.
* Use `async/await` for all asynchronous work. Avoid closure callbacks where possible.

## Cross-Framework API Compatibility
**This is the source SDK.** Changes to its public API surface directly affect all downstream wrapper frameworks:

| Wrapper | Location | Bridge File |
|---------|----------|-------------|
| Flutter (`zerosettle`) | `../ZeroSettle-Flutter/` | `ios/Classes/ZeroSettlePlugin.swift` |
| React Native (`react-native-zerosettle-kit`) | `react-native-zerosettle-kit/` | `ios/RNZeroSettleKit.swift` |

### Before changing any public API:
1. **Audit impact** — Identify which wrapper bridge files reference the type/method being changed
2. **Update wrappers** — Modify bridge code, Dart/JS models, and serialization to match
3. **Build all targets** — Verify each wrapper compiles against the updated SDK
4. **Run all tests** — `flutter test` for Flutter, `npm test` for React Native, plus native tests
5. **Bump versions** — Update `ZeroSettleKit.podspec` version and all wrapper dependency constraints (see root `CLAUDE.md` for the full version file list)

### What counts as a public API change:
* Adding, removing, or renaming `public` types, methods, properties, or enum cases
* Changing method signatures (parameters, return types, throwability)
* Modifying model shapes that cross the bridge (serialization contract)
* Altering delegate/callback protocols

## Coding Standards
* **Access Control:** `public` for developer-facing API, `internal` for helpers. Be deliberate — every new `public` symbol is a commitment across all wrappers.
* **Error Handling:** Use `ZSError` enum. Never crash silently.
* **Neutral Language:** Use "External Purchase," "Alternative Billing," or "Web Checkout" — never "bypass" or "evade."

# CLAUDE.md - React Native ZeroSettle Kit

## Overview
`react-native-zerosettle-kit` is the React Native wrapper around the native `ZeroSettleKit` iOS SDK. It uses React Native's TurboModule/Bridge architecture to expose the SDK to JavaScript.

## Key Files
* `ios/RNZeroSettleKit.swift` — Native Swift bridge module
* `RNZeroSettleKit.podspec` — CocoaPods spec with `ZeroSettleKit` dependency
* `package.json` — npm package metadata and version
* `src/` — TypeScript/JavaScript API surface

## Cross-Framework API Compatibility
This module wraps `ZeroSettleKit`. When the source SDK's public API changes:
1. Update `ios/RNZeroSettleKit.swift` — bridge methods and serialization
2. Update TypeScript types and JS-side models to match new serialization
3. Run the test suite to verify correctness
4. Build the example app to verify native compilation

### Version Sync
When `ZeroSettleKit` bumps its version:
* Update `RNZeroSettleKit.podspec` → `s.dependency 'ZeroSettleKit', '~> X.Y.Z'` (add version constraint if missing)
* Update `package.json` → `version` (follow semver appropriate to the scope of changes)
* Update `RNZeroSettleKit.podspec` → `s.version` to match package.json

## Backward Compatibility
**Never introduce breaking changes unless explicitly approved by the user.** This wrapper is consumed by third-party React Native apps.

Safe (non-breaking) changes:
* Adding new optional properties with defaults
* Adding new API response fields (old clients ignore unknown keys)
* Adding new methods or types
* Adding new optional parameters with defaults to existing methods

Breaking changes (require explicit approval):
* Removing or renaming exported types, methods, or properties
* Changing method signatures or serialization keys/formats
* Removing fields that clients depend on
* Changing default values in ways that alter existing behavior

## Coding Standards
* Neutral language: "External Purchase," "Web Checkout" — never "bypass" or "evade"
* `ZeroSettle.shared` is `@MainActor`-isolated — bridge methods must dispatch to main actor
* Dates serialize as ISO 8601 strings across the bridge
* Errors should map native `ZSError` codes to JS-side typed exceptions

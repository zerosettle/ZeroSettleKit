# ZeroSettleKit — Distribution & Publishing Guide

This document covers how ZeroSettleKit is distributed across platforms, how to publish new versions, and how each integration works.

## Overview

| Platform | Package Manager | Package Name | Registry | Status |
|---|---|---|---|---|
| iOS / macOS (native) | Swift Package Manager | `ZeroSettleKit` | GitHub repo | Live |
| iOS / macOS (native) | CocoaPods | `ZeroSettleKit` | CocoaPods trunk | Live |
| Flutter | pub.dev | `zerosettle` | pub.dev | Live |
| React Native | npm | TBD | npm | Not started |

---

## iOS — Swift Package Manager (SPM)

**Repo:** `git@github.com:zerosettle/ZeroSettleKit.git`

Developers add the package in Xcode via File > Add Package Dependencies, or in their `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/zerosettle/ZeroSettleKit.git", from: "1.3.2")
]
```

### Publishing a new SPM version

SPM resolves directly from git tags. No registry push needed.

```bash
cd /path/to/ZeroSettleKit
git tag X.Y.Z
git push origin X.Y.Z
```

That's it — SPM consumers pick it up immediately.

---

## iOS — CocoaPods

**Pod name:** `ZeroSettleKit`
**Podspec:** `ZeroSettleKit.podspec` (in the repo root)
**Owners:** `ryan@zerosettle.io`, `gabe@zerosettle.io`

Developers add to their Podfile:

```ruby
pod 'ZeroSettleKit', '~> 1.3.2'
```

### How CocoaPods builds differ from SPM

CocoaPods compiles `Sources/ZeroSettleCore/**` and `Sources/ZeroSettleKit/**` into a **single module** called `ZeroSettleKit`. This is different from SPM, which treats them as two separate modules.

The `#if canImport(ZeroSettleCore)` guards in the source handle this — when there's no separate `ZeroSettleCore` module (CocoaPods), the inter-module imports are skipped. All types are directly available since they're compiled together.

**Important:** Because of the single-module compilation, type names must not collide with system frameworks. This is why the logger is named `ZSLogger` (not `Logger`, which would collide with `os.Logger`).

### Publishing a new CocoaPods version

1. Update the version in `ZeroSettleKit.podspec`:
   ```ruby
   s.version = 'X.Y.Z'
   ```

2. Commit, tag, and push:
   ```bash
   git add ZeroSettleKit.podspec
   git commit -m "Bump podspec to X.Y.Z"
   git tag X.Y.Z
   git push origin main
   git push origin X.Y.Z
   ```

3. Validate:
   ```bash
   pod lib lint ZeroSettleKit.podspec --allow-warnings
   ```

4. Publish:
   ```bash
   pod trunk push ZeroSettleKit.podspec --allow-warnings
   ```

5. CDN propagation takes 5–30 minutes. To verify:
   ```bash
   pod trunk info ZeroSettleKit
   ```

### Managing CocoaPods owners

```bash
# Add a new owner
pod trunk add-owner ZeroSettleKit someone@zerosettle.io

# See current owners
pod trunk info ZeroSettleKit
```

---

## Flutter

**Repo:** `git@github.com:zerosettle/ZeroSettle-Flutter.git`
**Plugin podspec:** `ios/zerosettle.podspec`

### How it works

The Flutter plugin is a thin Dart wrapper around the native SDK. On iOS, it pulls ZeroSettleKit via CocoaPods (declared as `s.dependency 'ZeroSettleKit'` in the plugin's podspec). No xcframework is checked into the Flutter repo.

### Developer installation (via pub.dev)

```yaml
# pubspec.yaml
dependencies:
  zerosettle: ^1.3.0
```

### Developer installation (via git)

```yaml
# pubspec.yaml
dependencies:
  zerosettle:
    git:
      url: https://github.com/zerosettle/ZeroSettle-Flutter.git
```

### Publishing to pub.dev

1. Ensure `pubspec.yaml` has proper metadata:
   ```yaml
   name: zerosettle
   description: "ZeroSettle SDK for Flutter — Merchant of Record web checkout."
   version: 0.1.0
   homepage: https://zerosettle.io
   repository: https://github.com/zerosettle/ZeroSettle-Flutter
   ```

2. Dry run:
   ```bash
   dart pub publish --dry-run
   ```

3. Publish:
   ```bash
   dart pub publish
   ```
   This opens a browser for Google account authentication. The first person to publish becomes the uploader.

4. Add additional uploaders:
   ```bash
   dart pub uploader add someone@zerosettle.io
   ```

### Updating the Flutter plugin for a new native SDK version

1. Update `ios/zerosettle.podspec`:
   ```ruby
   s.dependency 'ZeroSettleKit', '~> X.Y.Z'
   ```

2. If Dart API changes are needed, update `lib/` files.

3. Commit and push (or publish to pub.dev).

---

## React Native (future)

Not yet started. Typical structure:

```
ZeroSettleKit-ReactNative/
├── package.json          # npm package
├── src/                  # TypeScript wrapper
├── ios/
│   ├── ZeroSettleKit.podspec   # CocoaPods dependency on ZeroSettleKit
│   └── ZeroSettleKitModule.swift  # Native bridge
├── android/              # Android implementation
└── example/              # Example RN app
```

The iOS side would use the same CocoaPods dependency (`ZeroSettleKit`) that the Flutter plugin uses. The pattern is identical — a thin native bridge that calls into the SDK, with CocoaPods pulling the compiled source.

To publish: `npm publish` (after `npm login`).

---

## XCFramework (binary distribution)

The repo includes `build_xcframework.sh` for building a pre-compiled binary. This is useful for:
- Developers who can't compile from source
- CI environments where build time matters
- Future private distribution (e.g., direct download from your site)

```bash
cd /path/to/ZeroSettleKit
./build_xcframework.sh
# Output: ZeroSettleKit.xcframework/
```

The script builds directly from the Swift package (no wrapper Xcode project), archives for device + simulator, injects the Swift module interfaces, and verifies the output.

**Note:** The xcframework is gitignored and is not used by the Flutter plugin (which compiles from source via CocoaPods).

---

## Version Checklist

When releasing a new version, update these in order:

1. **ZeroSettleKit source** — make your changes, commit
2. **`ZeroSettleKit.podspec`** — bump `s.version`
3. **`Configuration.sdkVersion`** — bump to match in `Sources/ZeroSettleKit/Configuration.swift`. The backend reads this from the `X-ZS-SDK-Version` header to gate features (e.g., the deferred-mode pivot in `backend/api/services/sdk_version.py:MIN_DEFERRED_VERSION`). Pinned tests in `Tests/ZeroSettleKitTests/ConfigurationTests.swift` and `BackendHeaderTests.swift` assert exact equality and will fail if you forget.
4. **Git tag** — `git tag X.Y.Z && git push origin X.Y.Z`
5. **CocoaPods** — `pod trunk push ZeroSettleKit.podspec --allow-warnings`
6. **Flutter podspec** — update `s.dependency 'ZeroSettleKit', '~> X.Y.Z'`
7. **Flutter pubspec** — bump `version:` if publishing to pub.dev
8. **Publish Flutter** — `dart pub publish` (or just push to git)

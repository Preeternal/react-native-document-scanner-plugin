# Releases

## v0.4.0 New Architecture & Swift Package Manager

### Breaking changes

- Removed the legacy React Native bridge implementation. The package is now New Architecture-only.
- The iOS deployment target now follows `min_ios_version_supported` from React Native.

### Added

- Added Swift Package Manager support for iOS via `Package.swift` while retaining CocoaPods compatibility.
- Added an RN 0.87 `example-spm` app and CI coverage for podless iOS integration with `npx react-native spm`.
- Added Android-only native scanner UI controls to `scanDocument(...)` and `scanAndAnalyzeDocument(...)`:
  - `galleryImportAllowed` lets capture-sensitive workflows such as KYC, proof-of-delivery, and inspections require a newly captured image instead of accepting a gallery import. It defaults to `true`, preserving the existing scanner behavior.
  - `scannerMode` selects ML Kit's `base`, `baseWithFilter`, or `full` feature set. It defaults to `full`, preserving the existing filters and ML-powered cleanup.
  - Both options configure the existing Google scanner UI and do not add a custom camera implementation. iOS ignores them because VisionKit exposes no equivalent settings.

### Changed

- Updated the main example and development toolchain to React Native 0.85 and React 19.2.
- Updated the example to Android SDK 36, Java 17, Gradle 9.3.1, and the current RN 0.85 iOS project structure.
- Updated the project to `create-react-native-library` 0.63.0 conventions, including Metro export conditions, Jest preset, TypeScript strict API conditions, Turborepo configuration, and native module registration.

### Fixed

- Restored automatic `NSCameraUsageDescription` configuration for Expo/EAS builds. The config plugin now accepts an optional `cameraPermission`, preserves an existing description, and otherwise supplies a default value.

---

## v0.3.0 – Capture + Analysis Pipeline Release

## Highlights

- Added single-call capture + analysis pipeline:
  - `scanAndAnalyzeDocument(options?)`
- Added new public analysis APIs for existing images:
  - `extractBarcodesFromImages(images, options?)`
  - `extractTextFromImages(images, options?)`
  - `analyzeScannedImages(images, options?)`
- Added document semantics extraction:
  - tables, regions, structured entities and key-value fields
- Improved iOS analysis pipeline: modern Vision path on iOS 26+, with fallback paths for earlier iOS versions and Simulator environments.
- Added Android analysis feature gating via Gradle property (`DocumentScanner_analysisFeatures`), so barcode/text analysis can be explicitly enabled for Android builds.

## Additional Notes

- Core `scanDocument(...)` flow remains supported and backward-compatible.
- This release expands the package from capture-only usage to capture + analysis workflows for scanner output, gallery images and file-based pipelines.
- No breaking changes are expected for existing `scanDocument(...)` integrations.

### Technical hardening (legacy API)

- Android (`scanDocument` flow): synchronized `launcher` initialization to avoid edge-case double registration on concurrent calls.
- Android (`scanDocument` flow): stronger `invalidate()` cleanup (`launcher.unregister()`, pending-state reset).
- Android (`scanDocument` flow): iterative page mapping in scan result processing (reduced recursion risk).

---

## v0.2.2 – Cross-Platform Polish

## Highlights

- Ensure Google’s document scanner respects system bars on Android 15+ and restore window flags when returning to React Native (Fix #2).
- Prevent repeated scans from crashing the Android bridge (`ObjectAlreadyConsumedException`) and validate returned URIs before resolving promises (Fix #142).
- Align Android/iOS responses: base64 conversion is guarded, file paths are checked for readability, and iOS trims/validates `file://` URLs (Fix #142).
- Restore DocumentScanner Objective‑C bridge so both old and new architectures build cleanly without warnings.

## Additional Notes

- Covers testing on both architectures, with New Arch guarding the TurboModule entry point while legacy builds continue to use the classic bridge.
- No API changes; consumers can upgrade directly.

### Docs: Sanitized scanner response

- Since v0.2.2 the module sanitizes scannedImages on both platforms. You no longer need to post‑filter in JS.
- Android: returns only non‑empty base64 strings or readable URIs (verified via ContentResolver).
- iOS: trims strings, normalizes file:// URLs to file paths and checks file existence.
- Backward‑compatible; no API changes.

Example:

```js
const { status, scannedImages } = await DocumentScanner.scanDocument({ responseType: 'imageFilePath' })
if (status === 'success' && scannedImages.length) {
  // All items are already valid
  setImage(scannedImages[0])
}
```

---

## v0.2.1 – Expo EAS iOS Swift Header Fix

- Fix: Reliable import of generated Swift header (DocumentScanner-Swift.h) using conditional __has_include + VisionKit import so Expo EAS cloud builds no longer fail with ‘DocumentScanner-Swift.h’ or VNDocumentCameraViewControllerDelegate not found.
- Ensures consistent iOS 13+ VisionKit availability for Expo SDK 53 development & production builds.

---

## v0.2.0 – TurboModule support & improvements

### Added

- Full support for React Native New Architecture (TurboModules).
- Prepared builds with react-native-builder-bob.

### Changed

- Updated dependencies to React Native 0.79.2 and React 19.0.0.
- Improved TypeScript definitions.

### Fixed

- Minor issues in Android and iOS build configurations.

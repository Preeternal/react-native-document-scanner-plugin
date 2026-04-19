# Document Scanner Example App

This workspace app demonstrates the full API surface of
`@preeternal/react-native-document-scanner-plugin`.

## What this example covers

- `pickImagesFromDevice()` via `@react-native-documents/picker`
- `pickImagesFromGallery()` via `react-native-image-picker`
- `scanDocument(...)`
- `extractBarcodesFromImages(...)`
- `extractTextFromImages(...)`
- `analyzeScannedImages(...)`
- `scanAndAnalyzeDocument(...)`

You can test post-processing API without opening scanner UI:
pick images from Files or directly from Photos and run extraction/analysis.

The screen also lets you interactively change:

- `responseType` (`imageFilePath` / `base64`)
- analysis `concurrency` (`1` / `2`)
- `ocrRotate180Fallback`
- `extract` stage toggles (`barcodes`, `text`, `tables`, `regions`, `structuredData`)
- barcode format allow-list

## Run from repo root

```bash
yarn install
```

Terminal 1:

```bash
yarn example start
```

Terminal 2:

```bash
# Android
yarn example android

# iOS
yarn example ios
```

## iOS setup

Install pods before the first run (or after native dependency changes):

```bash
cd example/ios
bundle install
bundle exec pod install
```

After adding/updating native picker dependencies (`@react-native-documents/picker`, `react-native-image-picker`), run pod install again.

## Android analysis feature flags

`example/android/gradle.properties` sets:

```properties
DocumentScanner_analysisFeatures=all
```

So the example app includes all optional native analysis stages by default.

Why this exists on Android:

- some analysis stages (barcode/OCR) require extra native dependencies;
- opt-in flags let production apps avoid extra APK/AAB size when they only need scan-only flow.

You can change this value for testing:

- `none` for scan-only build
- `barcode`
- `text`
- `tables`
- `all`

## Notes

- Picker mode uses native document provider URIs (`content://` / `file://`), so extraction works on existing files from device storage.
- Gallery mode uses `react-native-image-picker` and reads images from the Photos library.
- On Android, if a stage is not enabled in build flags, extraction methods return feature-disabled errors/status.
- On iOS, barcode/text analysis is available without extra build flags.

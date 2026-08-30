# @preeternal/react-native-document-scanner-plugin

[![npm version](https://img.shields.io/npm/v/@preeternal/react-native-document-scanner-plugin.svg)](https://www.npmjs.com/package/@preeternal/react-native-document-scanner-plugin)
[![npm downloads](https://img.shields.io/npm/dm/@preeternal/react-native-document-scanner-plugin.svg)](https://www.npmjs.com/package/@preeternal/react-native-document-scanner-plugin)

React Native document scanning for **capture-first** and **analysis-ready** workflows.

> Starting with `v0.4.0`, this package supports only React Native's New Architecture. Projects that still require the legacy bridge should stay on `v0.3.x`.

This fork started as a maintained alternative to the original `react-native-document-scanner-plugin`, but it has grown beyond a compatibility fork.
Today it gives you a clean separation between:

- **capture** — scan documents from camera UI;
- **analysis** — extract barcode / OCR / semantics from existing images;
- **combined flows** — scan and analyze in one call when your product needs both.

It is designed for apps that need more than “just scan a page”:

- e-sign and contract flows
- receipts and expense capture
- logistics / proof-of-delivery
- KYC and onboarding
- forms, IDs, invoices, and document intake

## Demo

https://github.com/user-attachments/assets/fda6d4d3-ac87-41d6-a04c-11f0ce08f5e8

## Why this fork

The upstream package now supports New Architecture too, which is great.
This package stays API-compatible for the core scan flow, while focusing on faster iteration and broader document-processing scenarios.

### What is different from upstream now

This is no longer only about TurboModules parity.
The fork has expanded into a broader mobile document workflow SDK with these additions:

- **separate public analysis APIs** for existing images:
  - `extractBarcodesFromImages(...)`
  - `extractTextFromImages(...)`
  - `analyzeScannedImages(...)`
- **combined capture + analysis flow** via `scanAndAnalyzeDocument(...)`
- **optional post-processing barcode extraction** with Android build-time feature gating
- **OCR extraction** with adaptive 180° fallback support
- **semantics-oriented analysis output**:
  - text blocks
  - inferred tables
  - regions
  - structured data / key-value style fields
- **response sanitization** on both platforms
- **Expo / EAS / CI hardening**
- **opt-in native debug logs** on iOS and Android
- ongoing maintenance and release cadence

## What this package is good at

Use it when you want a document capture layer that can also become the first stage of a richer pipeline:

- camera capture
- perspective-corrected scan results
- analysis from already existing images
- barcode extraction
- OCR extraction
- structured downstream payloads for app/backend workflows

Use your own or third-party tooling for final document authoring such as advanced PDF generation, searchable PDF composition, RTF export, signing, or storage pipelines.

## Installation

```bash
yarn add @preeternal/react-native-document-scanner-plugin
```

### iOS installation

1. Make sure the app uses React Native's New Architecture and the minimum iOS version required by its React Native release.
2. Add camera usage description to `Info.plist` (the Expo config plugin does this automatically; see [Camera permissions](#camera-permissions)):
   - `NSCameraUsageDescription`
3. Choose the integration used by the app.

#### CocoaPods (default)

React Native still selects CocoaPods by default. This library keeps its podspec,
so existing apps and React Native versions before 0.87 continue to install it normally:

```bash
cd ios && bundle exec pod install && cd ..
```

#### Swift Package Manager (React Native 0.87+)

The library also ships a self-managed `Package.swift`. React Native 0.87's
SwiftPM app integration is experimental and opt-in; CocoaPods remains the
default and supported production path.

To migrate an app once:

```bash
cd ios
npx react-native spm --deintegrate
```

After a fresh clone or in CI, initialize the generated SwiftPM workspace before
building:

```bash
cd ios
npx react-native spm
```

Every other native dependency in the app must also ship a compatible
`Package.swift`, or have a reproducible manifest generated with
`npx react-native spm scaffold` and persisted as a package patch.

### Android installation

The Google ML Kit document scanner does not require your app to declare or
request Android camera permission. Camera access performed independently by
your app or another dependency has its own permission requirements.
See [Camera permissions](#camera-permissions) below.

## Camera permissions

Camera permission requirements differ by platform and by whether you open the
scanner UI or only analyze existing images.

### iOS permission

`scanDocument()` presents Apple's `VNDocumentCameraViewController`, which
accesses the camera on behalf of your app. The app must therefore include
`NSCameraUsageDescription` in `Info.plist`. iOS may terminate an app that opens
the camera without this usage description.

For a bare React Native app that does not run the Expo config plugin, add the
key manually:

```xml
<key>NSCameraUsageDescription</key>
<string>Allow this app to scan documents</string>
```

Expo/EAS projects get this key from the built-in config plugin; see
[Expo / EAS configuration](#expo--eas-configuration).

The image-analysis APIs do not access the camera. An app that only calls
`extractBarcodesFromImages()`, `extractTextFromImages()`, or
`analyzeScannedImages()` does not need camera permission for those operations.

### Android permissions

`scanDocument()` runs through Google ML Kit and Google Play services. This
library does not declare `android.permission.CAMERA`, and your app does not need
to add or request it before opening the document scanner.

The Android-only `galleryImportAllowed` and `scannerMode` options configure the
existing Google scanner flow and do not change its permission requirements.
Barcode extraction, OCR, and semantic analysis over existing images also do not
require camera permission.

If your application or another dependency accesses the camera directly, follow
that camera integration's permission requirements independently.

The Expo config plugin does not add Android camera permission. Its
`analysisFeatures` setting only controls optional analysis dependencies.

## Quick start

### 1. Scan a document

```tsx
import React, { useEffect, useState } from 'react'
import { Image } from 'react-native'
import DocumentScanner from '@preeternal/react-native-document-scanner-plugin'

export default function App() {
  const [image, setImage] = useState<string | undefined>()

  useEffect(() => {
    const run = async () => {
      const { status, scannedImages } = await DocumentScanner.scanDocument({
        responseType: 'imageFilePath',
      })

      if (status === 'success' && scannedImages.length > 0) {
        setImage(scannedImages[0])
      }
    }

    run()
  }, [])

  return (
    <Image
      resizeMode="contain"
      style={{ width: '100%', height: '100%' }}
      source={image ? { uri: image } : undefined}
    />
  )
}
```

### 2. Extract barcodes from existing images

```ts
const result = await DocumentScanner.scanDocument({ responseType: 'imageFilePath' })

const barcodes = await DocumentScanner.extractBarcodesFromImages(
  result.scannedImages,
  {
    barcodeFormats: ['ean13', 'itf'],
    concurrency: 2,
  }
)
```

### 3. Extract OCR text from existing images

```ts
const textBlocks = await DocumentScanner.extractTextFromImages(images, {
  concurrency: 2,
  ocrRotate180Fallback: true,
})
```

If you only need plain text per page, use the `text` field on each block — it is already the full concatenated string for that image:

```ts
const pages = textBlocks.map((block) => ({
  pageIndex: block.sourceImageIndex,
  text: block.text,
}))
// [{ pageIndex: 0, text: "Invoice #1234\nTotal: $99.00\n..." }, ...]
```

The `lines` and `bbox` fields are there for advanced layout use cases (PDF composition, field highlighting, etc.) and can be ignored when you only need the text.

### 4. Run full analysis over scanned images

```ts
const analysis = await DocumentScanner.analyzeScannedImages(images, {
  extract: {
    barcodes: true,
    text: true,
    tables: true,
    structuredData: true,
  },
  concurrency: 2,
})
```

### 5. Scan and analyze in one call

```ts
const result = await DocumentScanner.scanAndAnalyzeDocument({
  responseType: 'imageFilePath',
  analysis: {
    extract: {
      barcodes: true,
      text: true,
    },
    concurrency: 2,
  },
})
```

## API overview

### Capture

- `scanDocument(options?)`

Open native document scanner UI and return sanitized images.

### Targeted analysis

- `extractBarcodesFromImages(images, options?)`
- `extractTextFromImages(images, options?)`

Run only the stage you need for lower latency and smaller payloads.

### Combined analysis

- `analyzeScannedImages(images, options)`
- `scanAndAnalyzeDocument(options)`

Use these when your app needs richer OCR and document understanding output.

## Recommended usage modes

### Simple mode

Request only the data your screen or business flow needs.
Examples:

```ts
{ extract: { barcodes: true } }
```

```ts
{ extract: { text: true } }
```

This keeps latency and payload size lower.

### Full mode

Request richer OCR semantics when you need downstream processing:

```ts
{
  extract: {
    text: true,
    tables: true,
    regions: true,
    structuredData: true,
  }
}
```

This is useful for receipts, forms, invoice parsing, document intake, or backend enrichment.

### Analysis guidance

Use `analyzeScannedImages(...)` when your pipeline needs structured OCR metadata rather than just raw capture output.

Typical patterns:

- **UI-driven flows** (fast, lightweight):
  request only what is needed:
  - `extract: { barcodes: true }`
  - `extract: { text: true }`

- **Document-processing flows** (backend enrichment, intake pipelines):
  request richer semantics:
  - `text`
  - `tables`
  - `regions`
  - `structuredData`

Notes:

- Full OCR payload is intended as a downstream foundation for searchable PDF generation, backend enrichment, invoice parsing, receipt processing, or custom document workflows.
- This library returns capture and analysis artifacts. Final document authoring (PDF composition, signing workflows, storage pipelines, or export formats such as RTF/searchable PDF) is expected to be handled by your app or third‑party tooling.

## Android feature gating for analysis

Barcode / OCR / table-related analysis features are opt-in on Android.
This keeps the core scanning package lean for apps that only need capture.

Enable features when building Android:

```bash
./gradlew :react-native-document-scanner-plugin:assemble -PDocumentScanner_analysisFeatures=barcode
```

Or configure `android/gradle.properties`:

```properties
DocumentScanner_analysisFeatures=barcode
```

Accepted values:

- `barcode`
- `text`
- `tables`
- comma-separated combinations such as `barcode,text`
- `all`
- `none`

If a feature is not enabled in the Android native build, the corresponding API returns `not_enabled` style behavior or rejects with a feature-specific error such as `barcode_not_enabled`.

### Expo / EAS configuration

For Expo managed and bare workflows, use the built-in config plugin instead of editing `gradle.properties` manually:

```json
{
  "expo": {
    "plugins": [
      [
        "@preeternal/react-native-document-scanner-plugin",
        {
          "analysisFeatures": "barcode,text",
          "cameraPermission": "Allow this app to scan documents"
        }
      ]
    ]
  }
}
```

Accepted values for `analysisFeatures`: `barcode`, `text`, `tables`, comma-separated combinations, `all`, or `none` (default when omitted).

The optional `cameraPermission` value becomes `NSCameraUsageDescription`. If it is omitted, the plugin preserves an existing description or adds `Allow $(PRODUCT_NAME) to access your camera`.

The plugin writes `DocumentScanner_analysisFeatures` to `android/gradle.properties` during `expo prebuild` / EAS build. iOS analysis features require no additional configuration — they are always available.

## iOS behavior: real device vs simulator

The library supports both, but analysis quality can differ by environment.

| Environment | Primary API path | Notes |
| ----------- | ---------------- | ----- |
| Real device (modern iOS) | `RecognizeDocumentsRequest` when available | Best reference for final quality validation |
| Simulator (modern iOS) | Modern path may run, but Vision results can differ | Use for integration, not final barcode quality decisions |
| Older iOS versions | Legacy Vision fallback path | Stable compatibility-focused behavior |

### Practical guidance

- Use Simulator for fast integration work.
- Validate barcode and OCR quality on a real device before release.
- If Simulator and device differ, trust real-device output.

### Why this matters

Apple Vision APIs can behave differently between Simulator and real hardware, especially for barcode detection.

Practical expectations:

- Simulator is reliable for integration and iteration.
- Real devices should be used for validating OCR/barcode quality before release.
- If Simulator and device outputs differ, treat real-device output as the source of truth for tuning and production decisions.

## Response sanitization

Returned `scannedImages` are sanitized natively on both platforms, so you do not need to manually post-filter invalid entries in JS.

- Android:
  - base64 responses are filtered to non-empty strings
  - URI responses are checked for readability through `ContentResolver`
- iOS:
  - strings are trimmed
  - `file://` URLs are normalized
  - file existence is checked before returning

Example:

```ts
const { status, scannedImages } = await DocumentScanner.scanDocument({
  responseType: 'imageFilePath',
})

if (status === 'success' && scannedImages.length > 0) {
  // safe to use
  setImage(scannedImages[0])
}
```

## Documentation

- [`scanDocument(...)`](#scandocument)
- [`extractBarcodesFromImages(...)`](#extractbarcodesfromimages)
- [`extractTextFromImages(...)`](#extracttextfromimages)
- [`analyzeScannedImages(...)`](#analyzescannedimages)
- [`scanAndAnalyzeDocument(...)`](#scanandanalyzedocument)
- [Response sanitization](#response-sanitization)
- [Interfaces](#interfaces)
- [Enums](#enums)
- [Camera permissions](#camera-permissions)

### scanDocument(...)

```typescript
scanDocument(options?: ScanDocumentOptions | undefined) => Promise<ScanDocumentResponse>
```

Opens native camera UI and starts document scanning.

#### Android native scanner options

By default, the Android scanner allows gallery import and uses ML Kit's `full`
feature set. Restrict those capabilities only when your workflow needs it:

```ts
const result = await DocumentScanner.scanDocument({
  galleryImportAllowed: false,
  scannerMode: 'baseWithFilter',
})
```

`galleryImportAllowed: false` requires capture during the current session, which
is useful for KYC, proof-of-delivery, or inspections.

| `scannerMode`    | Native scanner features                         |
| ---------------- | ----------------------------------------------- |
| `base`           | Capture and basic page editing                  |
| `baseWithFilter` | Base features plus image filters                |
| `full`           | Filters plus ML cleanup; default                 |

Both options are Android-only, configure the existing Google scanner UI, and do
not change camera permission requirements.

| Param         | Type                                                                |
| ------------- | ------------------------------------------------------------------- |
| **`options`** | <code><a href="#scandocumentoptions">ScanDocumentOptions</a></code> |

**Returns:** <code>Promise&lt;<a href="#scandocumentresponse">ScanDocumentResponse</a>&gt;</code>

### extractBarcodesFromImages(...)

```typescript
extractBarcodesFromImages(
  images: string[],
  options?: ExtractBarcodesFromImagesOptions | undefined
) => Promise<Barcode[]>
```

Extracts barcodes from existing images without opening scanner UI.

| Param         | Type                                                                                                   |
| ------------- | ------------------------------------------------------------------------------------------------------ |
| **`images`**  | <code>string[]</code>                                                                                  |
| **`options`** | <code><a href="#extractbarcodesfromimagesoptions">ExtractBarcodesFromImagesOptions</a></code>          |

**Returns:** <code>Promise&lt;<a href="#barcode">Barcode</a>[]&gt;</code>

### extractTextFromImages(...)

```typescript
extractTextFromImages(
  images: string[],
  options?: ExtractTextFromImagesOptions | undefined
) => Promise<TextBlock[]>
```

Extracts OCR text blocks from existing images without opening scanner UI.

| Param         | Type                                                                                                   |
| ------------- | ------------------------------------------------------------------------------------------------------ |
| **`images`**  | <code>string[]</code>                                                                                  |
| **`options`** | <code><a href="#extracttextfromimagesoptions">ExtractTextFromImagesOptions</a></code> |

**Returns:** <code>Promise&lt;<a href="#textblock">TextBlock</a>[]&gt;</code>

Notes:

- Android requires `DocumentScanner_analysisFeatures` to include `text` or `tables`.
- iOS is available by default.
- `ocrRotate180Fallback` is optional for this method and defaults to `false`.
- `textTimeoutMs` (Android-only) can override per-image OCR timeout. Default: `25000ms`.

### analyzeScannedImages(...)

```typescript
analyzeScannedImages(
  images: string[],
  options: AnalyzeScannedImagesOptions
) => Promise<AnalysisResult>
```

Universal post-processing over scanned images.
Barcode extraction, OCR text, table inference, region inference, and structured data extraction run natively.

`ocrRotate180Fallback` is enabled by default for this method (`true`) and only performs an extra 180° OCR pass when the first pass is weak.

Advanced timeout options:

- `barcodeTimeoutMs` (Android-only): per-image barcode extraction timeout. Default `10000ms`.
- `textTimeoutMs` (Android-only): per-image OCR extraction timeout. Default `25000ms`.
- Values are clamped natively to a safe range.

```ts
const analysis = await DocumentScanner.analyzeScannedImages(scannedImages, {
  extract: { barcodes: true },
  barcodeFormats: ['qr', 'ean13'],
  concurrency: 2,
})
```

**Returns:** <code>Promise&lt;<a href="#analysisresult">AnalysisResult</a>&gt;</code>

### scanAndAnalyzeDocument(...)

```typescript
scanAndAnalyzeDocument(
  options: ScanAndAnalyzeDocumentOptions
) => Promise<ScanAndAnalyzeDocumentResponse>
```

Convenience API for one-call flow:

```ts
scanDocument(...) -> analyzeScannedImages(...)
```

```ts
const result = await DocumentScanner.scanAndAnalyzeDocument({
  responseType: 'imageFilePath',
  analysis: {
    extract: { barcodes: true },
    barcodeFormats: ['qr'],
    concurrency: 2,
  },
})
```

**Returns:** <code>Promise&lt;<a href="#scanandanalyzedocumentresponse">ScanAndAnalyzeDocumentResponse</a>&gt;</code>

## Interfaces

### ScanDocumentResponse

- `scannedImages`: `string[]` — Array of valid file URIs or base64 strings, already sanitized by the native module.
- `status`: [`ScanDocumentResponseStatus`](#scandocumentresponsestatus) — Indicates whether scan completed successfully or was cancelled by the user.

### ScanDocumentOptions

- `croppedImageQuality`: `number` — Cropped image quality from `0` to `100`. Default: `100`.
- `maxNumDocuments`: `number` — Android only: maximum number of captured pages. Default: `undefined`.
- `galleryImportAllowed`: `boolean` — Android only: show or hide gallery import in the native scanner. Default: `true`. Disable it when the workflow requires a newly captured image.
- `scannerMode`: `'base' | 'baseWithFilter' | 'full'` — Android only: select basic editing, editing with filters, or the complete ML cleanup toolset. Default: `'full'`.
- `responseType`: [`ResponseType`](#responsetype) — Result format on success. Default: `ResponseType.ImageFilePath`.

### ExtractBarcodesFromImagesOptions

- `barcodeFormats`: [`Barcode`](#barcode)`['format'][]` — Optional allow-list of normalized barcode formats. Default: `undefined`.
- `concurrency`: `1 | 2` — Maximum native worker concurrency. Clamped to `1..2`. Default: `2`.
- `barcodeTimeoutMs`: `number` — Android-only per-image barcode extraction timeout (milliseconds). Default: `10000`.

### ExtractTextFromImagesOptions

- `concurrency`: `1 | 2` — Maximum native worker concurrency. Clamped to `1..2`. Default: `2`.
- `ocrRotate180Fallback`: `boolean` — Run an extra 180° OCR pass only when the first pass returns too little text. Default: `false`.
- `textTimeoutMs`: `number` — Android-only per-image OCR extraction timeout (milliseconds). Default: `25000`.

### AnalyzeExtractOptions

- `barcodes`: `boolean` — Enable barcode extraction stage.
- `text`: `boolean` — Enable OCR text extraction stage.
- `tables`: `boolean` — Enable table inference from OCR lines.
- `regions`: `boolean` — Enable zone or region inference from OCR blocks.
- `structuredData`: `boolean` — Enable entity and key-value inference from OCR output.

### AnalyzeScannedImagesOptions

- `extract`: [`AnalyzeExtractOptions`](#analyzeextractoptions) — Extractor toggles for image analysis.
- `barcodeFormats`: [`Barcode`](#barcode)`['format'][]` — Optional barcode format allow-list.
- `concurrency`: `1 | 2` — Native worker concurrency for barcode/OCR stages.
- `ocrRotate180Fallback`: `boolean` — Adaptive OCR fallback for text/semantics stages. Defaults to `true`.
- `barcodeTimeoutMs`: `number` — Android-only per-image barcode extraction timeout (milliseconds). Default: `10000`.
- `textTimeoutMs`: `number` — Android-only per-image OCR extraction timeout (milliseconds). Default: `25000`.

### AnalysisResult

- `status`: `'success' | 'partial' | 'failed' | 'not_enabled'` — Aggregate status of requested analysis stages.
- `barcodes`: [`Barcode`](#barcode)`[]` — Extracted barcodes when requested and available.
- `textBlocks`: [`TextBlock`](#textblock)`[]` — Canonical OCR text block field.
- `text`: [`TextBlock`](#textblock)`[]` — Backward-compatible alias for `textBlocks`.
- `tables`: [`TableBlock`](#tableblock)`[]` — Inferred tables from OCR lines.
- `regions`: [`Region`](#region)`[]` — Inferred document zones.
- `structuredData`: [`StructuredData`](#structureddata) — Inferred entities and key-value style fields.

### ScanAndAnalyzeDocumentOptions

- Includes all [`ScanDocumentOptions`](#scandocumentoptions).
- `analysis`: [`AnalyzeScannedImagesOptions`](#analyzescannedimagesoptions) — Analysis options for post-processing.

### ScanAndAnalyzeDocumentResponse

- `status`: [`ScanDocumentResponseStatus`](#scandocumentresponsestatus) — Scan status.
- `scannedImages`: `string[]` — Captured and sanitized images.
- `analysis`: [`AnalysisResult`](#analysisresult) — Post-processing result payload.

### Barcode

- `value`: `string` — Decoded barcode payload.
- `format`: `'aztec' | 'codabar' | 'code39' | 'code93' | 'code128' | 'dataMatrix' | 'ean8' | 'ean13' | 'itf' | 'pdf417' | 'qr' | 'upca' | 'upce' | 'unknown'` — Normalized barcode format.
- `sourceImageIndex`: `number` — Index of source image in `scannedImages`.

### TextBlock

- `text`: `string` — Full OCR text for this page. One block per source image.
- `sourceImageIndex`: `number` — Source image index in `scannedImages`.
- `bbox`: `{ left: number; top: number; width: number; height: number }` — Optional normalized bounding box (`0..1`).
- `lines`: `{ text: string; bbox?: { left: number; top: number; width: number; height: number } }[]` — OCR lines inside the block when available.

### TableBlock

- `sourceImageIndex`: `number` — Source image index in `scannedImages`.
- `rows`: `string[][]` — Inferred table rows and cell texts.
- `bbox`: `{ left: number; top: number; width: number; height: number }` — Optional normalized table bounds.

### Region

- `type`: `'header' | 'footer' | 'paragraph' | 'signature' | 'stamp' | 'unknown'` — Inferred region category.
- `sourceImageIndex`: `number` — Source image index in `scannedImages`.
- `bbox`: `{ left: number; top: number; width: number; height: number }` — Normalized region bounds (`0..1`).
- `score`: `number` — Optional heuristic confidence score.

### StructuredData

- `entities`: `{ type: 'phone' | 'email' | 'date' | 'amount' | 'id' | 'unknown'; value: string; sourceImageIndex: number }[]` — Inferred typed entities.
- `fields`: `{ key: string; value: string }[]` — Inferred key-value fields from OCR lines.

Normalization guarantees:

- `date` values are normalized to ISO-like `YYYY-MM-DD` when parser confidence is sufficient.
- `amount` values are normalized to `CODE value` when currency can be inferred.
- `phone` values are normalized to compact digit form, preserving `+` when present.
- `email` values are lowercased.
- `id` values are uppercased and compacted.
- `fields[].key` is sanitized to lowercase snake-like form on both platforms.

Best-effort quality note:

- Output shape is stable across platforms.
- Extraction quality may still vary depending on OS/runtime capabilities.

## Enums

### ScanDocumentResponseStatus

| Member          | Value             | Description                                        |
| :-------------- | :---------------- | :------------------------------------------------- |
| `Success`       | `'success'`       | Scan completed successfully.                       |
| `Cancel`        | `'cancel'`        | User closed the scanner before completing the flow.|

### ResponseType

| Member          | Value             | Description                                      |
| :-------------- | :---------------- | :----------------------------------------------- |
| `Base64`        | `'base64'`        | Return scanned images as base64 strings.         |
| `ImageFilePath` | `'imageFilePath'` | Return scanned images as image file paths.       |

## Migrating between upstream and this fork

Both packages are compatible for the core scan flow (`scanDocument(...)`).

### From this fork to upstream

```bash
yarn remove @preeternal/react-native-document-scanner-plugin
yarn add react-native-document-scanner-plugin
cd ios && pod install && cd -
```

### From upstream to this fork

```bash
yarn remove react-native-document-scanner-plugin
yarn add @preeternal/react-native-document-scanner-plugin
cd ios && pod install && cd -
```

## Roadmap direction

The current direction is to keep the package strong in the **capture + analysis** layer rather than turning it into a full document platform.

Areas that fit this package especially well:

- multi-page document flows
- image normalization and cleanup
- richer structured result payloads
- barcode / OCR / semantics as focused post-processing stages
- integration examples for upload, intake, logistics, and document workflows

## Contributing

- [Development workflow](CONTRIBUTING.md#development-workflow)
- [Native debug logs (iOS)](CONTRIBUTING.md#native-debug-logs-ios)
- [Native debug logs (Android)](CONTRIBUTING.md#native-debug-logs-android)
- [Sending a pull request](CONTRIBUTING.md#sending-a-pull-request)
- [Code of conduct](CODE_OF_CONDUCT.md)

## Credits

This project builds on the excellent work by [WebsiteBeaver/react-native-document-scanner-plugin](https://github.com/WebsiteBeaver/react-native-document-scanner-plugin).
The original repository is MIT-licensed, and original copyright notices are preserved in this fork’s LICENSE.

Barcode extraction logic in this repository was adapted from:

- [VictorAugustoDn/react-native-concluir-guias](https://github.com/VictorAugustoDn/react-native-concluir-guias)

## License

MIT

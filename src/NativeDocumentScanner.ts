import type { TurboModule } from 'react-native';
import { TurboModuleRegistry } from 'react-native';

/**
 * Android document scanner feature set.
 */
export type DocumentScannerMode = 'base' | 'baseWithFilter' | 'full';

/**
 * Options for document scanning.
 */
export interface ScanDocumentOptions {
  /**
   * The quality of the cropped image from 0 - 100. 100 is the best quality.
   * @default 100
   */
  croppedImageQuality?: number;

  /**
   * Android only: The maximum number of photos a user can take (not counting retakes).
   * @default undefined (no limit enforced by module)
   */
  maxNumDocuments?: number;

  /**
   * Android only: Whether the native scanner allows importing pages from the photo gallery.
   * Disable this for workflows that require a newly captured image, such as KYC or proof-of-delivery.
   * @default true
   */
  galleryImportAllowed?: boolean;

  /**
   * Android only: Controls the editing and cleanup features shown by the native scanner.
   * `base` provides basic document capture/editing, `baseWithFilter` adds filters,
   * and `full` also enables ML-powered cleanup.
   * @default 'full'
   */
  scannerMode?: DocumentScannerMode;

  /**
   * The response format on success. Either file paths or base64 images.
   * @default ResponseType.ImageFilePath
   */
  responseType?: ResponseType;
}

/**
 * Supported worker concurrency for image analysis.
 */
export type AnalysisConcurrency = 1 | 2;

/**
 * Options for barcode extraction from existing images.
 */
export interface ExtractBarcodesFromImagesOptions {
  /**
   * Optional allow-list of normalized formats to detect.
   * When omitted, all supported formats are scanned.
   */
  barcodeFormats?: BarcodeFormat[];

  /**
   * Maximum native worker concurrency. The implementation clamps this value to 1..2.
   * @default 2
   */
  concurrency?: AnalysisConcurrency;

  /**
   * Android-only. Per-image barcode extraction timeout in milliseconds.
   * Clamped natively to a safe range.
   * @default 10000
   */
  barcodeTimeoutMs?: number;
}

/**
 * Native request shape for extractBarcodesFromImages.
 */
export interface ExtractBarcodesFromImagesRequest extends ExtractBarcodesFromImagesOptions {
  /**
   * Array of image sources. Each item can be a file path, file URI, or base64.
   */
  images: string[];
}

/**
 * Options for OCR extraction from existing images.
 */
export interface ExtractTextFromImagesOptions {
  /**
   * Maximum native worker concurrency. The implementation clamps this value to 1..2.
   * @default 2
   */
  concurrency?: AnalysisConcurrency;

  /**
   * Enables an adaptive OCR fallback: run an additional 180° pass only when
   * the first pass returns no or very little text.
   * @default false
   */
  ocrRotate180Fallback?: boolean;

  /**
   * Android-only. Per-image OCR extraction timeout in milliseconds.
   * Clamped natively to a safe range.
   * @default 25000
   */
  textTimeoutMs?: number;
}

/**
 * Native request shape for extractTextFromImages.
 */
export interface ExtractTextFromImagesRequest extends ExtractTextFromImagesOptions {
  /**
   * Array of image sources. Each item can be a file path, file URI, or base64.
   */
  images: string[];
}

/**
 * Response type for scanned images.
 */
export enum ResponseType {
  /**
   * Return scanned images as base64 strings.
   */
  Base64 = 'base64',

  /**
   * Return scanned images as image file paths.
   */
  ImageFilePath = 'imageFilePath',
}

/**
 * Status of the scan flow.
 */
export enum ScanDocumentResponseStatus {
  /**
   * Scan completed successfully.
   */
  Success = 'success',

  /**
   * User canceled the scan.
   */
  Cancel = 'cancel',
}

/**
 * Normalized barcode format values exposed by the JS API.
 */
export type BarcodeFormat =
  | 'aztec'
  | 'codabar'
  | 'code39'
  | 'code93'
  | 'code128'
  | 'dataMatrix'
  | 'ean8'
  | 'ean13'
  | 'itf'
  | 'pdf417'
  | 'qr'
  | 'upca'
  | 'upce'
  | 'unknown';

/**
 * Single extracted barcode result.
 */
export type Barcode = {
  value: string;
  format: BarcodeFormat;
  sourceImageIndex: number;
};

export type NormalizedBoundingBox = {
  left: number;
  top: number;
  width: number;
  height: number;
};

export type TextLine = {
  text: string;
  bbox?: NormalizedBoundingBox;
  confidence?: number;
};

export type TextBlock = {
  text: string;
  sourceImageIndex: number;
  bbox?: NormalizedBoundingBox;
  confidence?: number;
  lines?: TextLine[];
};

export type TableCell = {
  text: string;
  row: number;
  column: number;
  sourceImageIndex: number;
  bbox?: NormalizedBoundingBox;
};

export type TableBlock = {
  rows: string[][];
  sourceImageIndex: number;
  bbox?: NormalizedBoundingBox;
  cells?: TableCell[];
};

export type RegionType =
  'header' | 'footer' | 'paragraph' | 'signature' | 'stamp' | 'unknown';

export type Region = {
  type: RegionType;
  sourceImageIndex: number;
  bbox: NormalizedBoundingBox;
  score?: number;
  text?: string;
};

export type StructuredEntityType =
  'phone' | 'email' | 'date' | 'amount' | 'id' | 'unknown';

export type StructuredEntity = {
  type: StructuredEntityType;
  value: string;
  sourceImageIndex: number;
  bbox?: NormalizedBoundingBox;
  confidence?: number;
};

export type StructuredField = {
  key: string;
  value: string;
};

export type StructuredData = {
  entities?: StructuredEntity[];
  fields?: StructuredField[];
};

/**
 * Extractor toggles for universal post-processing.
 */
export type AnalyzeExtractOptions = {
  barcodes?: boolean;
  text?: boolean;
  tables?: boolean;
  regions?: boolean;
  structuredData?: boolean;
};

/**
 * Options for universal post-processing across scanned images.
 */
export interface AnalyzeScannedImagesOptions extends ExtractBarcodesFromImagesOptions {
  extract: AnalyzeExtractOptions;

  /**
   * Android-only. Per-image OCR extraction timeout in milliseconds for text-related stages.
   * Clamped natively to a safe range.
   * @default 25000
   */
  textTimeoutMs?: number;

  /**
   * Enables adaptive OCR fallback for text/semantics stages.
   * @default true
   */
  ocrRotate180Fallback?: boolean;
}

/**
 * Native request shape for analyzeScannedImages.
 * Flattened to keep native codegen interop simple across architectures.
 */
export interface AnalyzeScannedImagesRequest extends ExtractBarcodesFromImagesOptions {
  images: string[];
  extractBarcodes?: boolean;
  extractText?: boolean;
  extractTables?: boolean;
  extractRegions?: boolean;
  extractStructuredData?: boolean;
  ocrRotate180Fallback?: boolean;
  /**
   * Android-only. Per-image OCR extraction timeout in milliseconds for text-related stages.
   */
  textTimeoutMs?: number;
}

/**
 * Status returned by universal post-processing.
 */
export type AnalysisResultStatus =
  'success' | 'partial' | 'failed' | 'not_enabled';

/**
 * Universal post-processing response.
 */
export type AnalysisResult = {
  status: AnalysisResultStatus;
  barcodes?: Barcode[];
  text?: TextBlock[];
  textBlocks?: TextBlock[];
  tables?: TableBlock[];
  regions?: Region[];
  structuredData?: StructuredData;
};

type ScanDocumentSuccess = {
  status: ScanDocumentResponseStatus.Success;
  scannedImages: string[];
};

type ScanDocumentCancel = {
  status: ScanDocumentResponseStatus.Cancel;
  scannedImages: [];
};

export type ScanDocumentResponse = ScanDocumentSuccess | ScanDocumentCancel;

/**
 * Codegen-facing scan response. The public discriminated union above is kept
 * separate because RN 0.85 Codegen does not accept enum member literals as
 * object property types.
 */
type NativeScanDocumentResponse = {
  status: string;
  scannedImages: string[];
};

/**
 * Convenience options for one-shot scan + analysis.
 */
export interface ScanAndAnalyzeDocumentOptions extends ScanDocumentOptions {
  analysis: AnalyzeScannedImagesOptions;
}

/**
 * Convenience response for one-shot scan + analysis.
 */
export type ScanAndAnalyzeDocumentResponse = ScanDocumentResponse & {
  analysis: AnalysisResult;
};

/**
 * TurboModule spec.
 */
export interface Spec extends TurboModule {
  /**
   * Opens the camera UI and starts document scanning.
   * @param options Scan options.
   * @returns Promise with scan result.
   */
  scanDocument(
    options: ScanDocumentOptions
  ): Promise<NativeScanDocumentResponse>;

  /**
   * Extracts barcodes from existing images without opening scanner UI.
   * @param options Extraction request.
   * @returns Promise with flattened barcode list.
   */
  extractBarcodesFromImages(
    options: ExtractBarcodesFromImagesRequest
  ): Promise<Barcode[]>;

  /**
   * Extracts OCR text blocks from existing images without opening scanner UI.
   * @param options Extraction request.
   * @returns Promise with flattened text block list.
   */
  extractTextFromImages(
    options: ExtractTextFromImagesRequest
  ): Promise<TextBlock[]>;

  /**
   * Runs unified image analysis natively (barcode/OCR/tables/regions/structured data).
   * @param options Flattened analysis request.
   * @returns Promise with aggregate analysis result.
   */
  analyzeScannedImages(
    options: AnalyzeScannedImagesRequest
  ): Promise<AnalysisResult>;
}

const DocumentScanner =
  TurboModuleRegistry.getEnforcing<Spec>('DocumentScanner');

export default DocumentScanner;

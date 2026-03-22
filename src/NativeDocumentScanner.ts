import type { TurboModule } from 'react-native';
import { TurboModuleRegistry } from 'react-native';

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
}

/**
 * Native request shape for extractBarcodesFromImages.
 */
export interface ExtractBarcodesFromImagesRequest
  extends ExtractBarcodesFromImagesOptions {
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

/**
 * Placeholder shape for future OCR text blocks.
 */
export type TextBlock = {
  text: string;
  sourceImageIndex: number;
  confidence?: number;
};

/**
 * Placeholder shape for future extracted tables.
 */
export type TableBlock = {
  rows: string[][];
  sourceImageIndex: number;
};

/**
 * Extractor toggles for universal post-processing.
 */
export type AnalyzeExtractOptions = {
  barcodes?: boolean;
  text?: boolean;
  tables?: boolean;
  structuredData?: boolean;
};

/**
 * Options for universal post-processing across scanned images.
 */
export interface AnalyzeScannedImagesOptions
  extends ExtractBarcodesFromImagesOptions {
  extract: AnalyzeExtractOptions;
}

/**
 * Status returned by universal post-processing.
 */
export type AnalysisResultStatus =
  | 'success'
  | 'partial'
  | 'failed'
  | 'not_enabled';

/**
 * Universal post-processing response.
 */
export type AnalysisResult = {
  status: AnalysisResultStatus;
  barcodes?: Barcode[];
  text?: TextBlock[];
  tables?: TableBlock[];
  structuredData?: Record<string, unknown>;
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
  scanDocument(options: ScanDocumentOptions): Promise<ScanDocumentResponse>;

  /**
   * Extracts barcodes from existing images without opening scanner UI.
   * @param options Extraction request.
   * @returns Promise with flattened barcode list.
   */
  extractBarcodesFromImages(
    options: ExtractBarcodesFromImagesRequest
  ): Promise<Barcode[]>;
}

const DocumentScanner =
  TurboModuleRegistry.getEnforcing<Spec>('DocumentScanner');

export default DocumentScanner;

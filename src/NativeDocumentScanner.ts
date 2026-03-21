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

  /**
   * When enabled, the module extracts barcodes from captured images as post-processing.
   * @default false
   */
  extractBarcodes?: boolean;

  /**
   * Optional allow-list of normalized barcode formats for extraction.
   * Effective only when barcode extraction is requested.
   */
  barcodeFormats?: BarcodeFormat[];
}

/**
 * Options for barcode extraction from existing images.
 */
export interface ExtractBarcodesFromImagesOptions {
  /**
   * Optional allow-list of normalized formats to detect.
   * When omitted, all supported formats are scanned.
   */
  barcodeFormats?: BarcodeFormat[];
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
 * Status for optional barcode extraction.
 */
export type BarcodeExtractionStatus = 'success' | 'not_enabled' | 'failed';

type ScanDocumentSuccess = {
  status: ScanDocumentResponseStatus.Success;
  scannedImages: string[];
  barcodes?: Barcode[];
  barcodeExtractionStatus?: BarcodeExtractionStatus;
};

type ScanDocumentCancel = {
  status: ScanDocumentResponseStatus.Cancel;
  scannedImages: [];
  barcodes?: Barcode[];
  barcodeExtractionStatus?: BarcodeExtractionStatus;
};

export type ScanDocumentResponse = ScanDocumentSuccess | ScanDocumentCancel;

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

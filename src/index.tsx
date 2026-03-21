import DocumentScanner, {
  ResponseType,
  ScanDocumentResponseStatus,
  type Barcode,
  type BarcodeExtractionStatus,
  type BarcodeFormat,
  type ExtractBarcodesFromImagesOptions,
  type ScanDocumentOptions,
  type ScanDocumentResponse,
} from './NativeDocumentScanner';

export function scanDocument(
  options: ScanDocumentOptions = {}
): Promise<ScanDocumentResponse> {
  if (!options.responseType) {
    options.responseType = ResponseType.ImageFilePath;
  }
  return DocumentScanner.scanDocument(options);
}

export function extractBarcodesFromImages(
  images: string[],
  options: ExtractBarcodesFromImagesOptions = {}
): Promise<Barcode[]> {
  return DocumentScanner.extractBarcodesFromImages({
    images,
    barcodeFormats: options.barcodeFormats,
  });
}

export { ResponseType, ScanDocumentResponseStatus };

export type {
  Barcode,
  BarcodeExtractionStatus,
  BarcodeFormat,
  ExtractBarcodesFromImagesOptions,
  ScanDocumentOptions,
  ScanDocumentResponse,
};

export default {
  extractBarcodesFromImages,
  scanDocument,
};

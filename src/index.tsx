import DocumentScanner, {
  ResponseType,
  ScanDocumentResponseStatus,
  type AnalysisResult,
  type AnalyzeScannedImagesOptions,
  type Barcode,
  type ExtractBarcodesFromImagesOptions,
  type ScanAndAnalyzeDocumentOptions,
  type ScanAndAnalyzeDocumentResponse,
  type ScanDocumentOptions,
  type ScanDocumentResponse,
} from './NativeDocumentScanner';

const DEFAULT_ANALYSIS_CONCURRENCY = 2;

function clampAnalysisConcurrency(
  value: number | undefined
): 1 | 2 | undefined {
  if (value === undefined) {
    return undefined;
  }

  return value <= 1 ? 1 : 2;
}

function normalizeBarcodeOptions(
  options: ExtractBarcodesFromImagesOptions = {}
): ExtractBarcodesFromImagesOptions {
  return {
    barcodeFormats: options.barcodeFormats,
    concurrency:
      options.concurrency ??
      clampAnalysisConcurrency(DEFAULT_ANALYSIS_CONCURRENCY),
  };
}

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
  const normalizedOptions = normalizeBarcodeOptions(options);

  return DocumentScanner.extractBarcodesFromImages({
    images,
    barcodeFormats: normalizedOptions.barcodeFormats,
    concurrency: normalizedOptions.concurrency,
  });
}

function getErrorCode(error: unknown): string | undefined {
  if (!error || typeof error !== 'object') {
    return undefined;
  }

  const candidate = (error as { code?: unknown }).code;
  return typeof candidate === 'string' ? candidate : undefined;
}

export async function analyzeScannedImages(
  images: string[],
  options: AnalyzeScannedImagesOptions
): Promise<AnalysisResult> {
  const extract = options.extract ?? {};
  const wantsBarcodes = !!extract.barcodes;
  const wantsText = !!extract.text;
  const wantsTables = !!extract.tables;
  const wantsStructuredData = !!extract.structuredData;
  const wantsUnsupported = wantsText || wantsTables || wantsStructuredData;

  if (!wantsBarcodes && !wantsUnsupported) {
    return { status: 'success' };
  }

  if (!wantsBarcodes && wantsUnsupported) {
    return { status: 'not_enabled' };
  }

  try {
    const barcodes = await extractBarcodesFromImages(images, {
      barcodeFormats: options.barcodeFormats,
      concurrency: options.concurrency,
    });

    return {
      status: wantsUnsupported ? 'partial' : 'success',
      barcodes,
    };
  } catch (error) {
    const code = getErrorCode(error);
    if (code === 'barcode_not_enabled') {
      return { status: 'not_enabled' };
    }

    return { status: 'failed' };
  }
}

export async function scanAndAnalyzeDocument(
  options: ScanAndAnalyzeDocumentOptions
): Promise<ScanAndAnalyzeDocumentResponse> {
  const { analysis, ...scanOptions } = options;
  const scanResult = await scanDocument(scanOptions);
  const analysisResult = await analyzeScannedImages(
    scanResult.scannedImages,
    analysis
  );

  return {
    ...scanResult,
    analysis: analysisResult,
  };
}

export { ResponseType, ScanDocumentResponseStatus };

export type {
  AnalysisResult,
  AnalyzeScannedImagesOptions,
  Barcode,
  ExtractBarcodesFromImagesOptions,
  ScanAndAnalyzeDocumentOptions,
  ScanAndAnalyzeDocumentResponse,
  ScanDocumentOptions,
  ScanDocumentResponse,
};

export default {
  analyzeScannedImages,
  extractBarcodesFromImages,
  scanAndAnalyzeDocument,
  scanDocument,
};

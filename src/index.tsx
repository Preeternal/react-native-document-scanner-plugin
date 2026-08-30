import DocumentScanner, {
  ResponseType,
  ScanDocumentResponseStatus,
  type AnalysisResult,
  type AnalyzeScannedImagesOptions,
  type Barcode,
  type ExtractBarcodesFromImagesOptions,
  type ExtractTextFromImagesOptions,
  type Region,
  type StructuredData,
  type StructuredEntity,
  type TableBlock,
  type TextBlock,
  type ScanAndAnalyzeDocumentOptions,
  type ScanAndAnalyzeDocumentResponse,
  type ScanDocumentOptions,
  type ScanDocumentResponse,
} from './NativeDocumentScanner';

const DEFAULT_ANALYSIS_CONCURRENCY = 2;

type StageStatus = 'success' | 'not_enabled' | 'failed' | 'skipped';

type StageResult<T> = {
  status: StageStatus;
  value?: T;
};

type NativeAnalyzeFn = (options: {
  images: string[];
  extractBarcodes?: boolean;
  extractText?: boolean;
  extractTables?: boolean;
  extractRegions?: boolean;
  extractStructuredData?: boolean;
  barcodeFormats?: AnalyzeScannedImagesOptions['barcodeFormats'];
  concurrency?: AnalyzeScannedImagesOptions['concurrency'];
  barcodeTimeoutMs?: AnalyzeScannedImagesOptions['barcodeTimeoutMs'];
  textTimeoutMs?: AnalyzeScannedImagesOptions['textTimeoutMs'];
  ocrRotate180Fallback?: boolean;
}) => Promise<AnalysisResult>;

/**
 * Clamps analysis worker count to the supported native range (1..2).
 * `undefined` is preserved so native defaults may apply.
 */
function clampAnalysisConcurrency(
  value: number | undefined
): 1 | 2 | undefined {
  if (value === undefined) {
    return undefined;
  }

  return value <= 1 ? 1 : 2;
}

/**
 * Normalizes barcode extraction options for stable cross-platform defaults.
 * This helper is internal and not part of the public API contract.
 */
function normalizeBarcodeOptions(
  options: ExtractBarcodesFromImagesOptions = {}
): ExtractBarcodesFromImagesOptions {
  return {
    barcodeFormats: options.barcodeFormats,
    barcodeTimeoutMs: options.barcodeTimeoutMs,
    concurrency:
      options.concurrency ??
      clampAnalysisConcurrency(DEFAULT_ANALYSIS_CONCURRENCY),
  };
}

/**
 * Normalizes OCR extraction options for stable cross-platform defaults.
 * This helper is internal and not part of the public API contract.
 */
function normalizeTextOptions(
  options: ExtractTextFromImagesOptions = {}
): ExtractTextFromImagesOptions {
  return {
    ocrRotate180Fallback: options.ocrRotate180Fallback ?? false,
    textTimeoutMs: options.textTimeoutMs,
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
  return DocumentScanner.scanDocument(options) as Promise<ScanDocumentResponse>;
}

/**
 * Extracts barcodes from captured image sources without opening scanner UI.
 */
export function extractBarcodesFromImages(
  images: string[],
  options: ExtractBarcodesFromImagesOptions = {}
): Promise<Barcode[]> {
  const normalizedOptions = normalizeBarcodeOptions(options);

  return DocumentScanner.extractBarcodesFromImages({
    images,
    barcodeFormats: normalizedOptions.barcodeFormats,
    barcodeTimeoutMs: normalizedOptions.barcodeTimeoutMs,
    concurrency: normalizedOptions.concurrency,
  });
}

/**
 * Extracts OCR text blocks from captured image sources without opening scanner UI.
 */
export function extractTextFromImages(
  images: string[],
  options: ExtractTextFromImagesOptions = {}
): Promise<TextBlock[]> {
  const normalizedOptions = normalizeTextOptions(options);

  return DocumentScanner.extractTextFromImages({
    images,
    concurrency: normalizedOptions.concurrency,
    textTimeoutMs: normalizedOptions.textTimeoutMs,
    ocrRotate180Fallback: normalizedOptions.ocrRotate180Fallback,
  });
}

/**
 * Extracts a string error code from unknown thrown values.
 * Internal helper for stage status mapping.
 */
function getErrorCode(error: unknown): string | undefined {
  if (!error || typeof error !== 'object') {
    return undefined;
  }

  const candidate = (error as { code?: unknown }).code;
  return typeof candidate === 'string' ? candidate : undefined;
}

/**
 * Aggregates per-stage statuses into one public `AnalysisResult.status` value.
 * Rules are ordered to preserve backward-compatible semantics.
 */
function mergeStageStatuses(statuses: StageStatus[]): AnalysisResult['status'] {
  const requested = statuses.filter((status) => status !== 'skipped');
  if (requested.length === 0) {
    return 'success';
  }
  if (requested.every((status) => status === 'success')) {
    return 'success';
  }
  if (requested.every((status) => status === 'not_enabled')) {
    return 'not_enabled';
  }
  if (requested.some((status) => status === 'success')) {
    return 'partial';
  }
  return 'failed';
}

/**
 * Returns native unified analysis entry point if available in the compiled
 * native module. Missing method indicates stale native artifacts.
 */
function nativeAnalyzeScannedImages(): NativeAnalyzeFn | undefined {
  const module = DocumentScanner as unknown as {
    analyzeScannedImages?: NativeAnalyzeFn;
  };

  return module.analyzeScannedImages;
}

/**
 * Runs barcode stage using public extraction API and maps native errors to a
 * normalized internal stage status.
 */
async function runBarcodeStage(
  images: string[],
  options: AnalyzeScannedImagesOptions,
  wantsStage: boolean
): Promise<StageResult<Barcode[]>> {
  if (!wantsStage) {
    return { status: 'skipped' };
  }

  try {
    const value = await extractBarcodesFromImages(images, {
      barcodeFormats: options.barcodeFormats,
      concurrency: options.concurrency,
      barcodeTimeoutMs: options.barcodeTimeoutMs,
    });
    return {
      status: 'success',
      value,
    };
  } catch (error) {
    return {
      status:
        getErrorCode(error) === 'barcode_not_enabled'
          ? 'not_enabled'
          : 'failed',
    };
  }
}

/**
 * Runs OCR text stage using public extraction API and maps native errors to a
 * normalized internal stage status.
 */
async function runTextStage(
  images: string[],
  options: AnalyzeScannedImagesOptions,
  ocrRotate180Fallback: boolean,
  wantsStage: boolean
): Promise<StageResult<TextBlock[]>> {
  if (!wantsStage) {
    return { status: 'skipped' };
  }

  try {
    const value = await extractTextFromImages(images, {
      concurrency: options.concurrency,
      textTimeoutMs: options.textTimeoutMs,
      ocrRotate180Fallback,
    });
    return {
      status: 'success',
      value,
    };
  } catch (error) {
    return {
      status:
        getErrorCode(error) === 'text_not_enabled' ? 'not_enabled' : 'failed',
    };
  }
}

/**
 * Runs unified post-processing. Prefers native aggregate method and falls back
 * to staged extraction when native artifacts are stale.
 */
export async function analyzeScannedImages(
  images: string[],
  options: AnalyzeScannedImagesOptions
): Promise<AnalysisResult> {
  const extract = options.extract ?? {};
  const wantsBarcodes = !!extract.barcodes;
  const wantsText = !!extract.text;
  const wantsTables = !!extract.tables;
  const wantsRegions = !!extract.regions;
  const wantsStructuredData = !!extract.structuredData;
  const wantsTextPipeline =
    wantsText || wantsTables || wantsRegions || wantsStructuredData;
  const ocrRotate180Fallback = options.ocrRotate180Fallback ?? true;

  if (!wantsBarcodes && !wantsTextPipeline) {
    return { status: 'success' };
  }

  const nativeAnalyze = nativeAnalyzeScannedImages();
  if (nativeAnalyze) {
    try {
      return await nativeAnalyze({
        images,
        extractBarcodes: wantsBarcodes,
        extractText: wantsText,
        extractTables: wantsTables,
        extractRegions: wantsRegions,
        extractStructuredData: wantsStructuredData,
        barcodeFormats: options.barcodeFormats,
        concurrency: options.concurrency,
        barcodeTimeoutMs: options.barcodeTimeoutMs,
        textTimeoutMs: options.textTimeoutMs,
        ocrRotate180Fallback,
      });
    } catch {
      // Fallback for stale native artifacts.
    }
  }

  const [barcodeStage, textStage] = await Promise.all([
    runBarcodeStage(images, options, wantsBarcodes),
    runTextStage(images, options, ocrRotate180Fallback, wantsText),
  ]);

  const semanticsStage: StageStatus =
    wantsTables || wantsRegions || wantsStructuredData
      ? 'not_enabled'
      : 'skipped';

  const status = mergeStageStatuses([
    barcodeStage.status,
    textStage.status,
    semanticsStage,
  ]);

  const result: AnalysisResult = { status };

  if (barcodeStage.status === 'success') {
    result.barcodes = barcodeStage.value ?? [];
  }

  if (textStage.status === 'success') {
    const textBlocks = textStage.value ?? [];
    result.textBlocks = textBlocks;
    result.text = textBlocks;
  }

  return result;
}

/**
 * Convenience sugar for one-call scan + analysis flow.
 */
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
  ExtractTextFromImagesOptions,
  Region,
  StructuredData,
  StructuredEntity,
  TableBlock,
  TextBlock,
  ScanAndAnalyzeDocumentOptions,
  ScanAndAnalyzeDocumentResponse,
  ScanDocumentOptions,
  ScanDocumentResponse,
};

export default {
  analyzeScannedImages,
  extractBarcodesFromImages,
  extractTextFromImages,
  scanAndAnalyzeDocument,
  scanDocument,
};

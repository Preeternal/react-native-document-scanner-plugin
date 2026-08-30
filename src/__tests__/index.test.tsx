import { beforeEach, describe, expect, it, jest } from '@jest/globals';

import ScannerApi, { ResponseType } from '../index';
import NativeScanner from '../NativeDocumentScanner';

jest.mock('../NativeDocumentScanner', () => {
  const module = {
    scanDocument: jest.fn(),
    extractBarcodesFromImages: jest.fn(),
    extractTextFromImages: jest.fn(),
    analyzeScannedImages: jest.fn(),
  };

  return {
    __esModule: true,
    default: module,
    ResponseType: {
      Base64: 'base64',
      ImageFilePath: 'imageFilePath',
    },
    ScanDocumentResponseStatus: {
      Success: 'success',
      Cancel: 'cancel',
    },
  };
});

const native = NativeScanner as unknown as {
  scanDocument: ReturnType<typeof jest.fn>;
  extractBarcodesFromImages: ReturnType<typeof jest.fn>;
  extractTextFromImages: ReturnType<typeof jest.fn>;
  analyzeScannedImages: ReturnType<typeof jest.fn>;
};

describe('public scanner API', () => {
  beforeEach(() => {
    jest.clearAllMocks();
  });

  it('forwards Android native scanner UI options', async () => {
    native.scanDocument.mockResolvedValue({
      status: 'success',
      scannedImages: [],
    });

    await ScannerApi.scanDocument({
      responseType: ResponseType.ImageFilePath,
      galleryImportAllowed: false,
      scannerMode: 'baseWithFilter',
    });

    expect(native.scanDocument).toHaveBeenCalledWith({
      responseType: 'imageFilePath',
      galleryImportAllowed: false,
      scannerMode: 'baseWithFilter',
    });
  });

  it.each(['base', 'baseWithFilter', 'full'] as const)(
    'accepts and forwards scannerMode=%s',
    async (scannerMode) => {
      native.scanDocument.mockResolvedValue({
        status: 'success',
        scannedImages: [],
      });

      await ScannerApi.scanDocument({ scannerMode });

      expect(native.scanDocument).toHaveBeenCalledWith({
        responseType: 'imageFilePath',
        scannerMode,
      });
    }
  );

  it('forwards native scanner UI options through scanAndAnalyzeDocument', async () => {
    native.scanDocument.mockResolvedValue({
      status: 'success',
      scannedImages: ['file://scan.jpg'],
    });
    native.analyzeScannedImages.mockResolvedValue({ status: 'success' });

    await ScannerApi.scanAndAnalyzeDocument({
      galleryImportAllowed: false,
      scannerMode: 'base',
      analysis: {
        extract: { barcodes: true },
      },
    });

    expect(native.scanDocument).toHaveBeenCalledWith({
      responseType: 'imageFilePath',
      galleryImportAllowed: false,
      scannerMode: 'base',
    });
    expect(native.analyzeScannedImages).toHaveBeenCalledWith(
      expect.objectContaining({
        images: ['file://scan.jpg'],
        extractBarcodes: true,
      })
    );
  });
});

describe('public analysis API', () => {
  beforeEach(() => {
    jest.clearAllMocks();
  });

  it('normalizes barcode options and forwards timeout', async () => {
    native.extractBarcodesFromImages.mockResolvedValue([]);

    await ScannerApi.extractBarcodesFromImages(['file://a.jpg'], {
      barcodeFormats: ['ean13'],
      barcodeTimeoutMs: 9000,
    });

    expect(native.extractBarcodesFromImages).toHaveBeenCalledWith({
      images: ['file://a.jpg'],
      barcodeFormats: ['ean13'],
      barcodeTimeoutMs: 9000,
      concurrency: 2,
    });
  });

  it('normalizes text options and forwards timeout', async () => {
    native.extractTextFromImages.mockResolvedValue([]);

    await ScannerApi.extractTextFromImages(['file://b.jpg'], {
      textTimeoutMs: 20000,
    });

    expect(native.extractTextFromImages).toHaveBeenCalledWith({
      images: ['file://b.jpg'],
      concurrency: 2,
      textTimeoutMs: 20000,
      ocrRotate180Fallback: false,
    });
  });

  it('forwards timeout options to native analyze method', async () => {
    native.analyzeScannedImages.mockResolvedValue({ status: 'success' });

    await ScannerApi.analyzeScannedImages(['file://c.jpg'], {
      extract: { barcodes: true, text: true },
      barcodeTimeoutMs: 12000,
      textTimeoutMs: 30000,
    });

    expect(native.analyzeScannedImages).toHaveBeenCalledWith({
      images: ['file://c.jpg'],
      extractBarcodes: true,
      extractText: true,
      extractTables: false,
      extractRegions: false,
      extractStructuredData: false,
      barcodeFormats: undefined,
      concurrency: undefined,
      barcodeTimeoutMs: 12000,
      textTimeoutMs: 30000,
      ocrRotate180Fallback: true,
    });
  });
});

import { useMemo, useState } from 'react';
import {
  ActivityIndicator,
  Image,
  Pressable,
  ScrollView,
  StyleSheet,
  Switch,
  Text,
  View,
} from 'react-native';
import {
  SafeAreaProvider,
  SafeAreaView,
  useSafeAreaInsets,
} from 'react-native-safe-area-context';
import DocumentScanner, {
  ResponseType,
  type AnalysisResult,
  type AnalyzeScannedImagesOptions,
  type Barcode,
  type ScanAndAnalyzeDocumentResponse,
  type TextBlock,
} from '@preeternal/react-native-document-scanner-plugin';
import { launchImageLibrary } from 'react-native-image-picker';

type ExtractToggles = {
  barcodes: boolean;
  text: boolean;
  tables: boolean;
  regions: boolean;
  structuredData: boolean;
};

type ActionKey =
  | 'pickGallery'
  | 'scan'
  | 'extractBarcodes'
  | 'extractText'
  | 'analyze'
  | 'scanAndAnalyze';

type BarcodeFormatValue = Barcode['format'];
type PageSource = 'scanner' | 'gallery';

const BARCODE_FORMAT_OPTIONS: BarcodeFormatValue[] = [
  'qr',
  'ean13',
  'ean8',
  'upca',
  'upce',
  'code128',
  'itf',
  'pdf417',
  'aztec',
  'dataMatrix',
];

const INITIAL_EXTRACT: ExtractToggles = {
  barcodes: true,
  text: true,
  tables: true,
  regions: true,
  structuredData: true,
};

const INITIAL_BARCODE_FORMATS: BarcodeFormatValue[] = [];

function formatError(error: unknown): string {
  if (typeof error === 'string') {
    return error;
  }

  if (error && typeof error === 'object') {
    const native = error as { code?: unknown; message?: unknown };
    const code = typeof native.code === 'string' ? native.code : undefined;
    const message =
      typeof native.message === 'string' ? native.message : undefined;

    if (code || message) {
      return [code, message].filter(Boolean).join(': ');
    }
  }

  return 'Unknown error';
}

function toDisplayImageUri(source: string, responseType: ResponseType): string {
  if (responseType === ResponseType.Base64) {
    return source.startsWith('data:')
      ? source
      : `data:image/jpeg;base64,${source}`;
  }

  if (
    source.startsWith('file://') ||
    source.startsWith('content://') ||
    source.startsWith('data:') ||
    source.startsWith('http://') ||
    source.startsWith('https://')
  ) {
    return source;
  }

  if (source.startsWith('/')) {
    return `file://${source}`;
  }

  return source;
}

function imageSourceScheme(source: string | undefined): string {
  if (!source) {
    return 'n/a';
  }
  const normalized = source.trim();
  const schemeEnd = normalized.indexOf('://');
  if (schemeEnd > 0) {
    return normalized.slice(0, schemeEnd).toLowerCase();
  }
  if (normalized.startsWith('/')) {
    return 'path';
  }
  return 'unknown';
}

function jsonPreview(value: unknown): string {
  const raw = JSON.stringify(value, null, 2);
  if (!raw) {
    return '';
  }

  if (raw.length <= 4000) {
    return raw;
  }

  return `${raw.slice(0, 4000)}\n...truncated`;
}

function toAnalyzeOptions(
  extract: ExtractToggles,
  concurrency: 1 | 2,
  barcodeFormats: BarcodeFormatValue[],
  ocrRotate180Fallback: boolean,
): AnalyzeScannedImagesOptions {
  return {
    extract,
    concurrency,
    barcodeFormats: barcodeFormats.length > 0 ? barcodeFormats : undefined,
    ocrRotate180Fallback,
  };
}

function ActionButton(props: {
  title: string;
  onPress: () => void;
  disabled?: boolean;
}) {
  const { title, onPress, disabled = false } = props;

  return (
    <Pressable
      style={[styles.actionButton, disabled && styles.actionButtonDisabled]}
      disabled={disabled}
      onPress={onPress}
    >
      <Text style={styles.actionButtonText}>{title}</Text>
    </Pressable>
  );
}

function ToggleChip(props: {
  label: string;
  active: boolean;
  onPress: () => void;
}) {
  const { label, active, onPress } = props;

  return (
    <Pressable
      style={[styles.chip, active ? styles.chipActive : styles.chipInactive]}
      onPress={onPress}
    >
      <Text style={[styles.chipText, active && styles.chipTextActive]}>
        {label}
      </Text>
    </Pressable>
  );
}

function JsonCard(props: { title: string; value: unknown }) {
  const { title, value } = props;

  return (
    <View style={styles.card}>
      <Text style={styles.cardTitle}>{title}</Text>
      <Text style={styles.jsonText} selectable>
        {jsonPreview(value)}
      </Text>
    </View>
  );
}

function AppContent() {
  const insets = useSafeAreaInsets();
  const [responseType, setResponseType] = useState<ResponseType>(
    ResponseType.ImageFilePath,
  );
  const [concurrency, setConcurrency] = useState<1 | 2>(2);
  const [ocrRotate180Fallback, setOcrRotate180Fallback] =
    useState<boolean>(true);
  const [extract, setExtract] = useState<ExtractToggles>(INITIAL_EXTRACT);
  const [barcodeFormats, setBarcodeFormats] = useState<BarcodeFormatValue[]>(
    INITIAL_BARCODE_FORMATS,
  );

  const [activeAction, setActiveAction] = useState<ActionKey | null>(null);
  const [lastError, setLastError] = useState<string | null>(null);

  const [scanStatus, setScanStatus] = useState<string | null>(null);
  const [pageSource, setPageSource] = useState<PageSource | null>(null);
  const [scannedImages, setScannedImages] = useState<string[]>([]);
  const [imagesResponseType, setImagesResponseType] = useState<ResponseType>(
    ResponseType.ImageFilePath,
  );
  const [selectedImageIndex, setSelectedImageIndex] = useState<number>(0);

  const [barcodes, setBarcodes] = useState<Barcode[]>([]);
  const [textBlocks, setTextBlocks] = useState<TextBlock[]>([]);
  const [analysis, setAnalysis] = useState<AnalysisResult | null>(null);
  const [scanAndAnalyzeResult, setScanAndAnalyzeResult] =
    useState<ScanAndAnalyzeDocumentResponse | null>(null);

  const analysisOptions = useMemo(
    () =>
      toAnalyzeOptions(
        extract,
        concurrency,
        barcodeFormats,
        ocrRotate180Fallback,
      ),
    [extract, concurrency, barcodeFormats, ocrRotate180Fallback],
  );

  const selectedImageSource = scannedImages[selectedImageIndex];
  const firstImageScheme = imageSourceScheme(scannedImages[0]);
  const selectedImageUri = selectedImageSource
    ? toDisplayImageUri(selectedImageSource, imagesResponseType)
    : null;

  const isBusy = activeAction !== null;

  const runAction = async (key: ActionKey, task: () => Promise<void>) => {
    if (isBusy) {
      return;
    }

    setActiveAction(key);
    setLastError(null);

    try {
      await task();
    } catch (error) {
      setLastError(formatError(error));
    } finally {
      setActiveAction(null);
    }
  };

  const toggleExtract = (name: keyof ExtractToggles) => {
    setExtract(prev => ({
      ...prev,
      [name]: !prev[name],
    }));
  };

  const toggleBarcodeFormat = (format: BarcodeFormatValue) => {
    setBarcodeFormats(prev =>
      prev.includes(format)
        ? prev.filter(candidate => candidate !== format)
        : [...prev, format],
    );
  };

  const clearResults = () => {
    setLastError(null);
    setScanStatus(null);
    setPageSource(null);
    setScannedImages([]);
    setSelectedImageIndex(0);
    setBarcodes([]);
    setTextBlocks([]);
    setAnalysis(null);
    setScanAndAnalyzeResult(null);
  };

  const scanDocument = async () => {
    await runAction('scan', async () => {
      const result = await DocumentScanner.scanDocument({ responseType });

      setScanStatus(result.status);
      setPageSource('scanner');
      setScannedImages(result.scannedImages);
      setImagesResponseType(responseType);
      setSelectedImageIndex(0);

      setBarcodes([]);
      setTextBlocks([]);
      setAnalysis(null);
      setScanAndAnalyzeResult(null);
    });
  };

  const pickImagesFromGallery = async () => {
    await runAction('pickGallery', async () => {
      const response = await launchImageLibrary({
        mediaType: 'photo',
        selectionLimit: 0,
        includeBase64: false,
      });

      if (response.didCancel) {
        return;
      }

      if (response.errorCode) {
        const message = response.errorMessage
          ? `${response.errorCode}: ${response.errorMessage}`
          : response.errorCode;
        setLastError(message);
        return;
      }

      const pickedUris = (response.assets ?? [])
        .map(item =>
          typeof item.uri === 'string' ? item.uri.trim() : undefined,
        )
        .filter((uri): uri is string => !!uri);

      if (pickedUris.length === 0) {
        setLastError('Gallery returned no readable image URIs.');
        return;
      }

      setScanStatus('picked');
      setPageSource('gallery');
      setScannedImages(pickedUris);
      setImagesResponseType(ResponseType.ImageFilePath);
      setSelectedImageIndex(0);

      setBarcodes([]);
      setTextBlocks([]);
      setAnalysis(null);
      setScanAndAnalyzeResult(null);
    });
  };

  const extractBarcodes = async () => {
    if (scannedImages.length === 0) {
      setLastError('Scan a document first.');
      return;
    }

    await runAction('extractBarcodes', async () => {
      const result = await DocumentScanner.extractBarcodesFromImages(
        scannedImages,
        {
          concurrency,
          barcodeFormats:
            barcodeFormats.length > 0 ? barcodeFormats : undefined,
        },
      );

      setBarcodes(result);
    });
  };

  const extractText = async () => {
    if (scannedImages.length === 0) {
      setLastError('Scan a document first.');
      return;
    }

    await runAction('extractText', async () => {
      const result = await DocumentScanner.extractTextFromImages(
        scannedImages,
        {
          concurrency,
          ocrRotate180Fallback,
        },
      );

      setTextBlocks(result);
    });
  };

  const analyzeImages = async () => {
    if (scannedImages.length === 0) {
      setLastError('Scan a document first.');
      return;
    }

    await runAction('analyze', async () => {
      const result = await DocumentScanner.analyzeScannedImages(
        scannedImages,
        analysisOptions,
      );

      setAnalysis(result);
      if (result.barcodes) {
        setBarcodes(result.barcodes);
      }

      const textResult = result.textBlocks ?? result.text;
      if (textResult) {
        setTextBlocks(textResult);
      }
    });
  };

  const scanAndAnalyze = async () => {
    await runAction('scanAndAnalyze', async () => {
      const result = await DocumentScanner.scanAndAnalyzeDocument({
        responseType,
        analysis: analysisOptions,
      });

      setScanAndAnalyzeResult(result);
      setScanStatus(result.status);
      setPageSource('scanner');
      setScannedImages(result.scannedImages);
      setImagesResponseType(responseType);
      setSelectedImageIndex(0);

      setAnalysis(result.analysis);
      setBarcodes(result.analysis.barcodes ?? []);
      setTextBlocks(result.analysis.textBlocks ?? result.analysis.text ?? []);
    });
  };

  return (
    <SafeAreaView edges={['top', 'right', 'left']} style={styles.safeArea}>
      <ScrollView
        contentContainerStyle={[
          styles.content,
          { paddingBottom: insets.bottom },
        ]}
      >
        <Text style={styles.title}>Document Scanner Example</Text>
        <Text style={styles.subtitle}>
          Full demo for scan + files/gallery pickers + barcode + OCR +
          semantics.
        </Text>

        <View style={styles.card}>
          <Text style={styles.cardTitle}>scanDocument options</Text>
          <Text style={styles.label}>responseType</Text>
          <View style={styles.rowWrap}>
            <ToggleChip
              label="imageFilePath"
              active={responseType === ResponseType.ImageFilePath}
              onPress={() => setResponseType(ResponseType.ImageFilePath)}
            />
            <ToggleChip
              label="base64"
              active={responseType === ResponseType.Base64}
              onPress={() => setResponseType(ResponseType.Base64)}
            />
          </View>

          <Text style={styles.label}>analysis concurrency</Text>
          <View style={styles.rowWrap}>
            <ToggleChip
              label="1"
              active={concurrency === 1}
              onPress={() => setConcurrency(1)}
            />
            <ToggleChip
              label="2"
              active={concurrency === 2}
              onPress={() => setConcurrency(2)}
            />
          </View>

          <View style={styles.switchRow}>
            <Text style={styles.label}>ocrRotate180Fallback</Text>
            <Switch
              value={ocrRotate180Fallback}
              onValueChange={setOcrRotate180Fallback}
            />
          </View>
        </View>

        <View style={styles.card}>
          <Text style={styles.cardTitle}>analyzeScannedImages extract</Text>
          <View style={styles.rowWrap}>
            {(Object.keys(extract) as Array<keyof ExtractToggles>).map(key => (
              <ToggleChip
                key={key}
                label={key}
                active={extract[key]}
                onPress={() => toggleExtract(key)}
              />
            ))}
          </View>

          <Text style={styles.label}>
            barcodeFormats allow-list (empty = all)
          </Text>
          <View style={styles.rowWrap}>
            {BARCODE_FORMAT_OPTIONS.map(format => (
              <ToggleChip
                key={format}
                label={format}
                active={barcodeFormats.includes(format)}
                onPress={() => toggleBarcodeFormat(format)}
              />
            ))}
          </View>
          <Text style={styles.hint}>
            Selected:{' '}
            {barcodeFormats.length > 0 ? barcodeFormats.join(', ') : 'all'}
          </Text>
        </View>

        <View style={styles.card}>
          <Text style={styles.cardTitle}>Actions</Text>
          <View style={styles.actionsGrid}>
            <ActionButton
              title="pickImagesFromGallery()"
              onPress={pickImagesFromGallery}
              disabled={isBusy}
            />
            <ActionButton
              title="scanDocument()"
              onPress={scanDocument}
              disabled={isBusy}
            />
            <ActionButton
              title="extractBarcodesFromImages()"
              onPress={extractBarcodes}
              disabled={isBusy}
            />
            <ActionButton
              title="extractTextFromImages()"
              onPress={extractText}
              disabled={isBusy}
            />
            <ActionButton
              title="analyzeScannedImages()"
              onPress={analyzeImages}
              disabled={isBusy}
            />
            <ActionButton
              title="scanAndAnalyzeDocument()"
              onPress={scanAndAnalyze}
              disabled={isBusy}
            />
            <ActionButton
              title="Clear results"
              onPress={clearResults}
              disabled={isBusy}
            />
          </View>

          {isBusy && (
            <View style={styles.busyRow}>
              <ActivityIndicator size="small" color="#0b6dff" />
              <Text style={styles.busyText}>Running: {activeAction}</Text>
            </View>
          )}

          {lastError && (
            <Text style={styles.errorText} selectable>
              {lastError}
            </Text>
          )}
        </View>

        <View style={styles.card}>
          <Text style={styles.cardTitle}>Summary</Text>
          <Text style={styles.summaryLine}>
            scan status: {scanStatus ?? 'n/a'}
          </Text>
          <Text style={styles.summaryLine}>source: {pageSource ?? 'n/a'}</Text>
          <Text style={styles.summaryLine}>
            barcodeFormats:{' '}
            {barcodeFormats.length > 0 ? barcodeFormats.join(', ') : 'all'}
          </Text>
          <Text style={styles.summaryLine}>
            first image scheme: {firstImageScheme}
          </Text>
          <Text style={styles.summaryLine}>
            scannedImages: {scannedImages.length}
          </Text>
          <Text style={styles.summaryLine}>barcodes: {barcodes.length}</Text>
          <Text style={styles.summaryLine}>
            textBlocks: {textBlocks.length}
          </Text>
          <Text style={styles.summaryLine}>
            analysis status: {analysis?.status ?? 'n/a'}
          </Text>
        </View>

        <View style={styles.card}>
          <Text style={styles.cardTitle}>Pages (scanner or picker)</Text>
          {scannedImages.length === 0 && (
            <Text style={styles.placeholderText}>
              No pages yet. Use scanner, Files picker, or gallery picker.
            </Text>
          )}

          {scannedImages.length > 0 && (
            <>
              <ScrollView horizontal showsHorizontalScrollIndicator={false}>
                <View style={styles.thumbnailRow}>
                  {scannedImages.map((source, index) => {
                    const uri = toDisplayImageUri(source, imagesResponseType);
                    return (
                      <Pressable
                        key={`page-${index}`}
                        style={[
                          styles.thumbnail,
                          selectedImageIndex === index &&
                            styles.thumbnailActive,
                        ]}
                        onPress={() => setSelectedImageIndex(index)}
                      >
                        <Image source={{ uri }} style={styles.thumbnailImage} />
                        <Text style={styles.thumbnailText}>#{index}</Text>
                      </Pressable>
                    );
                  })}
                </View>
              </ScrollView>

              {selectedImageUri && (
                <Image
                  source={{ uri: selectedImageUri }}
                  style={styles.previewImage}
                />
              )}
            </>
          )}
        </View>

        {barcodes.length > 0 && <JsonCard title="Barcodes" value={barcodes} />}
        {textBlocks.length > 0 && (
          <JsonCard title="Text blocks" value={textBlocks} />
        )}
        {analysis && <JsonCard title="Analysis result" value={analysis} />}
        {scanAndAnalyzeResult && (
          <JsonCard
            title="scanAndAnalyzeDocument result"
            value={scanAndAnalyzeResult}
          />
        )}
      </ScrollView>
    </SafeAreaView>
  );
}

export default function App() {
  return (
    <SafeAreaProvider>
      <AppContent />
    </SafeAreaProvider>
  );
}

const styles = StyleSheet.create({
  safeArea: {
    flex: 1,
    backgroundColor: '#f4f7fb',
  },
  content: {
    padding: 16,
    paddingBottom: 32,
    gap: 12,
  },
  title: {
    fontSize: 28,
    fontWeight: '700',
    color: '#152340',
  },
  subtitle: {
    fontSize: 14,
    lineHeight: 20,
    color: '#42567c',
  },
  card: {
    backgroundColor: '#ffffff',
    borderRadius: 14,
    padding: 14,
    borderWidth: StyleSheet.hairlineWidth,
    borderColor: '#dbe3f1',
    gap: 10,
  },
  cardTitle: {
    fontSize: 16,
    fontWeight: '700',
    color: '#1c2f57',
  },
  label: {
    fontSize: 13,
    fontWeight: '600',
    color: '#334c7f',
  },
  rowWrap: {
    flexDirection: 'row',
    flexWrap: 'wrap',
    gap: 8,
  },
  switchRow: {
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'space-between',
  },
  chip: {
    borderRadius: 999,
    paddingHorizontal: 12,
    paddingVertical: 8,
    borderWidth: 1,
  },
  chipActive: {
    backgroundColor: '#0b6dff',
    borderColor: '#0b6dff',
  },
  chipInactive: {
    backgroundColor: '#ffffff',
    borderColor: '#c7d4ea',
  },
  chipText: {
    fontSize: 12,
    fontWeight: '600',
    color: '#31538f',
  },
  chipTextActive: {
    color: '#ffffff',
  },
  hint: {
    fontSize: 12,
    color: '#4b5f85',
  },
  actionsGrid: {
    gap: 8,
  },
  actionButton: {
    backgroundColor: '#0b6dff',
    borderRadius: 10,
    paddingVertical: 12,
    paddingHorizontal: 14,
  },
  actionButtonDisabled: {
    opacity: 0.45,
  },
  actionButtonText: {
    color: '#ffffff',
    fontSize: 14,
    fontWeight: '700',
    textAlign: 'center',
  },
  busyRow: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: 8,
    marginTop: 2,
  },
  busyText: {
    color: '#24467a',
    fontSize: 13,
    fontWeight: '600',
  },
  errorText: {
    color: '#b4233a',
    fontSize: 13,
    lineHeight: 18,
    fontWeight: '600',
  },
  summaryLine: {
    color: '#203a68',
    fontSize: 13,
  },
  placeholderText: {
    color: '#58709a',
    fontSize: 13,
  },
  thumbnailRow: {
    flexDirection: 'row',
    gap: 10,
  },
  thumbnail: {
    width: 96,
    borderRadius: 10,
    borderWidth: 2,
    borderColor: 'transparent',
    overflow: 'hidden',
    backgroundColor: '#eef3fd',
  },
  thumbnailActive: {
    borderColor: '#0b6dff',
  },
  thumbnailImage: {
    width: 96,
    height: 96,
    backgroundColor: '#d7e2f7',
  },
  thumbnailText: {
    textAlign: 'center',
    color: '#25457a',
    fontWeight: '700',
    paddingVertical: 6,
  },
  previewImage: {
    width: '100%',
    height: 420,
    borderRadius: 12,
    resizeMode: 'contain',
    backgroundColor: '#e8eef9',
  },
  jsonText: {
    fontFamily: 'Courier',
    fontSize: 12,
    lineHeight: 18,
    color: '#243c69',
  },
});

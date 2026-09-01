const pkg = require('./package.json');
let configPlugins;
try {
  configPlugins = require('@expo/config-plugins');
} catch (error) {
  if (error && error.code !== 'MODULE_NOT_FOUND') {
    throw error;
  }
  configPlugins = require('expo/config-plugins');
}

const { createRunOncePlugin, withInfoPlist } = configPlugins;
const withAndroidGradleProperties =
  typeof configPlugins.withAndroidGradleProperties === 'function'
    ? configPlugins.withAndroidGradleProperties
    : configPlugins.withGradleProperties;

if (typeof withInfoPlist !== 'function') {
  throw new Error(
    `${pkg.name}: incompatible expo config-plugins API (missing Info.plist helper).`
  );
}

if (typeof withAndroidGradleProperties !== 'function') {
  throw new Error(
    `${pkg.name}: incompatible expo config-plugins API (missing Gradle properties helper).`
  );
}

const VALID_FEATURES = new Set(['barcode', 'text', 'tables']);
const PROPERTY_KEY = 'DocumentScanner_analysisFeatures';
const CAMERA_USAGE = 'Allow $(PRODUCT_NAME) to access your camera';

function normalizeAnalysisFeatures(raw) {
  if (raw == null || raw === '') {
    return 'none';
  }

  const value = String(raw).trim().toLowerCase();

  if (value === 'none') {
    return 'none';
  }

  if (value === 'all') {
    return 'all';
  }

  const features = value
    .split(',')
    .map((f) => f.trim())
    .filter(Boolean);

  const invalid = features.filter((f) => !VALID_FEATURES.has(f));
  if (invalid.length > 0) {
    throw new Error(
      `${pkg.name}: invalid analysisFeatures value(s): ${invalid.join(', ')}. ` +
        `Expected comma-separated combination of 'barcode', 'text', 'tables', or 'all' / 'none'.`
    );
  }

  return features.join(',');
}

function withDocumentScanner(config, props = {}) {
  const analysisFeatures = normalizeAnalysisFeatures(props.analysisFeatures);
  const cameraPermission = props.cameraPermission;

  config = withInfoPlist(config, (mod) => {
    mod.modResults.NSCameraUsageDescription =
      cameraPermission ||
      mod.modResults.NSCameraUsageDescription ||
      CAMERA_USAGE;

    return mod;
  });

  return withAndroidGradleProperties(config, (mod) => {
    const existing = mod.modResults.find(
      (item) => item.type === 'property' && item.key === PROPERTY_KEY
    );

    if (existing) {
      existing.value = analysisFeatures;
    } else {
      mod.modResults.push({
        type: 'property',
        key: PROPERTY_KEY,
        value: analysisFeatures,
      });
    }

    return mod;
  });
}

module.exports = createRunOncePlugin(
  withDocumentScanner,
  pkg.name,
  pkg.version
);

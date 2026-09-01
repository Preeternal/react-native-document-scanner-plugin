const { beforeEach, describe, expect, it } = require('@jest/globals');

const mockCreateRunOncePlugin = jest.fn((plugin) => plugin);
const mockWithInfoPlist = jest.fn((config, action) => {
  action({ modResults: config.infoPlist });
  return config;
});
const mockWithAndroidGradleProperties = jest.fn((config, action) => {
  action({ modResults: config.gradleProperties });
  return config;
});

jest.mock(
  '@expo/config-plugins',
  () => ({
    createRunOncePlugin: mockCreateRunOncePlugin,
    withInfoPlist: mockWithInfoPlist,
    withAndroidGradleProperties: mockWithAndroidGradleProperties,
  }),
  { virtual: true }
);

const withDocumentScanner = require('../../app.plugin.js');

function makeConfig({ cameraUsage, analysisFeatures } = {}) {
  return {
    infoPlist: cameraUsage ? { NSCameraUsageDescription: cameraUsage } : {},
    gradleProperties: analysisFeatures
      ? [
          {
            type: 'property',
            key: 'DocumentScanner_analysisFeatures',
            value: analysisFeatures,
          },
        ]
      : [],
  };
}

describe('Expo config plugin', () => {
  beforeEach(() => {
    jest.clearAllMocks();
  });

  it('configures camera permission and Android analysis features together', () => {
    const config = makeConfig();

    withDocumentScanner(config, {
      cameraPermission: 'Allow this app to scan documents',
      analysisFeatures: ' Barcode, Text ',
    });

    expect(config.infoPlist.NSCameraUsageDescription).toBe(
      'Allow this app to scan documents'
    );
    expect(config.gradleProperties).toContainEqual({
      type: 'property',
      key: 'DocumentScanner_analysisFeatures',
      value: 'barcode,text',
    });
  });

  it('preserves an existing camera usage description', () => {
    const config = makeConfig({ cameraUsage: 'Existing camera description' });

    withDocumentScanner(config, { analysisFeatures: 'none' });

    expect(config.infoPlist.NSCameraUsageDescription).toBe(
      'Existing camera description'
    );
  });

  it('adds a default camera usage description when none is configured', () => {
    const config = makeConfig();

    withDocumentScanner(config);

    expect(config.infoPlist.NSCameraUsageDescription).toBe(
      'Allow $(PRODUCT_NAME) to access your camera'
    );
  });

  it('updates an existing Android analysis property without duplicating it', () => {
    const config = makeConfig({ analysisFeatures: 'barcode' });

    withDocumentScanner(config, { analysisFeatures: 'all' });

    expect(config.gradleProperties).toEqual([
      {
        type: 'property',
        key: 'DocumentScanner_analysisFeatures',
        value: 'all',
      },
    ]);
  });
});

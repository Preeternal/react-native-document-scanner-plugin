/**
 * @format
 */

import ReactTestRenderer from 'react-test-renderer';
import App from '../src/App';

jest.mock('@preeternal/react-native-document-scanner-plugin', () => ({
  __esModule: true,
  default: {
    analyzeScannedImages: jest.fn(),
    extractBarcodesFromImages: jest.fn(),
    extractTextFromImages: jest.fn(),
    scanAndAnalyzeDocument: jest.fn(),
    scanDocument: jest.fn(),
  },
  ResponseType: {
    Base64: 'base64',
    ImageFilePath: 'imageFilePath',
  },
}));

jest.mock('react-native-image-picker', () => ({
  launchImageLibrary: jest.fn(),
}));

test('renders correctly', async () => {
  await ReactTestRenderer.act(() => {
    ReactTestRenderer.create(<App />);
  });
});

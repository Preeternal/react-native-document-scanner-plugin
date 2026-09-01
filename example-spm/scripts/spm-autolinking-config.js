const { spawnSync } = require('node:child_process');
const path = require('node:path');

const projectRoot = path.resolve(__dirname, '..');
const cliPath = require.resolve('@react-native-community/cli/build/bin.js', {
  paths: [projectRoot],
});

const result = spawnSync(process.execPath, [cliPath, 'config'], {
  cwd: projectRoot,
  encoding: 'utf8',
  maxBuffer: 64 * 1024 * 1024,
});

if (result.status !== 0) {
  process.stderr.write(result.stderr || 'react-native config failed\n');
  process.exit(result.status || 1);
}

const config = JSON.parse(result.stdout);

// CLI 20.2 discovers Apple projects through Podfile lookup. This example is
// intentionally SwiftPM-only, so provide the project metadata without adding
// a fake Podfile solely for discovery.
config.project = config.project || {};
config.project.ios = {
  sourceDir: path.join(projectRoot, 'ios'),
  xcodeProject: {
    name: 'DocumentScannerExampleSpm.xcodeproj',
    path: '.',
    isWorkspace: false,
  },
  automaticPodsInstallation: false,
  assets: [],
};

process.stdout.write(JSON.stringify(config));

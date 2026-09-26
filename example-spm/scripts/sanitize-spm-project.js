const fs = require('node:fs');
const path = require('node:path');

const iosRoot = path.resolve(__dirname, '..', 'ios');
const projectRoot = path.join(iosRoot, 'DocumentScannerExampleSpm.xcodeproj');
const projectPath = path.join(projectRoot, 'project.pbxproj');
const injectionPath = path.join(projectRoot, '.spm-injected.json');

// React Native 0.87.1 writes the current machine's absolute hermesc path into
// both generated files. Xcode resolves Hermes without it, so do not commit a
// developer- or CI-specific path.
const project = fs
  .readFileSync(projectPath, 'utf8')
  .replace(/^\s*HERMES_CLI_PATH = ".*";\r?\n/gm, '');
fs.writeFileSync(projectPath, project);

if (fs.existsSync(injectionPath)) {
  const injection = JSON.parse(fs.readFileSync(injectionPath, 'utf8'));
  for (const change of injection.buildSettingChanges ?? []) {
    change.createdScalars = (change.createdScalars ?? []).filter(
      (setting) => setting !== 'HERMES_CLI_PATH'
    );
  }

  // Clear the pre-hardening custom CLI wrapper before React Native reads the
  // injection state. Standard discovery now works through the Podfile stub.
  injection.configCommand = null;
  fs.writeFileSync(injectionPath, `${JSON.stringify(injection, null, 2)}\n`);
}

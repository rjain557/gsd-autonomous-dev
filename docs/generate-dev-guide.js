#!/usr/bin/env node

const { spawnSync } = require('child_process');
const path = require('path');

const scriptDir = __dirname;
const pythonScript = path.join(scriptDir, 'generate-docx.py');

function run(command, args) {
  return spawnSync(command, args, { stdio: 'inherit' });
}

let result = run('python', [pythonScript]);
if (result.error && result.error.code === 'ENOENT') {
  result = run('python3', [pythonScript]);
}

if (result.error) {
  console.error('Failed to launch the Python docx generator.');
  console.error(`Tried: ${result.error.path}`);
  process.exit(1);
}

process.exit(result.status ?? 0);

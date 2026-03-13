const fs = require('fs');
const m = JSON.parse(fs.readFileSync('D:/vscode/tech-web-chatai.v8/tech-web-chatai.v8/.gsd/requirements/requirements-matrix.json', 'utf8'));

const sat = m.requirements.filter(r => r.status === 'satisfied');
const withFile = sat.filter(r => typeof r.satisfied_by === 'string' && r.satisfied_by.includes('src/'));
const withLines = sat.filter(r => typeof r.notes === 'string' && r.notes.includes('line '));
const noFile = sat.filter(r => typeof r.satisfied_by !== 'string' || !r.satisfied_by.includes('src/'));

console.log('=== Traceability Audit ===');
console.log('Satisfied:', sat.length);
console.log('With src/ file path:', withFile.length, `(${(withFile.length/sat.length*100).toFixed(1)}%)`);
console.log('With line refs in notes:', withLines.length, `(${(withLines.length/sat.length*100).toFixed(1)}%)`);
console.log('Missing/weak file ref:', noFile.length);
console.log('\nExamples missing file paths:');
noFile.slice(0, 8).forEach(r => {
  console.log(' ', r.id, '->', String(r.satisfied_by).substring(0, 80));
});

// Check what the pipeline Verify phase puts in satisfied_by
console.log('\nExamples WITH good traceability:');
withFile.slice(0, 5).forEach(r => {
  console.log(' ', r.id);
  console.log('    satisfied_by:', r.satisfied_by);
  console.log('    notes:', String(r.notes).substring(0, 120));
});

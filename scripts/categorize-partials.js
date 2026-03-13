const fs = require('fs');
const m = JSON.parse(fs.readFileSync('D:/vscode/tech-web-chatai.v8/tech-web-chatai.v8/.gsd/requirements/requirements-matrix.json', 'utf8'));
const par = m.requirements.filter(r => r.status === 'partial');

// Categorize: fixable-by-code vs infrastructure/docs-only
const codeFixable = [];
const infraOnly = [];

par.forEach(r => {
  const d = r.description.toLowerCase();
  const n = (r.notes || '').toLowerCase();

  // Infrastructure/deployment/docs — can't fix with code alone
  if (d.includes('azure') || d.includes('deployment') || d.includes('ci/cd') ||
      d.includes('github actions') || d.includes('disaster recovery') ||
      d.includes('sla targets') || d.includes('auto-scaling') ||
      d.includes('key vault') || d.includes('cdn') || d.includes('geo-redundant') ||
      d.includes('payment gateway') || d.includes('stripe')) {
    infraOnly.push(r);
  } else {
    codeFixable.push(r);
  }
});

console.log('=== CODE-FIXABLE (' + codeFixable.length + ') ===');
codeFixable.forEach(r => {
  console.log(r.id + ' | ' + r.interface + ' | ' + r.description.substring(0, 100));
});

console.log('\n=== INFRA/DOCS ONLY (' + infraOnly.length + ') ===');
infraOnly.forEach(r => {
  console.log(r.id + ' | ' + r.interface + ' | ' + r.description.substring(0, 100));
});

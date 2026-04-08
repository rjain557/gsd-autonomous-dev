const fs = require('fs');
const m = JSON.parse(fs.readFileSync('D:/vscode/tech-web-chatai.v8/tech-web-chatai.v8/.gsd/requirements/requirements-matrix.json', 'utf8'));

const par = m.requirements.filter(r => r.status === 'partial');
console.log('Total partial:', par.length);
console.log('');

const byInterface = {};
par.forEach(r => {
  const k = r.interface || 'unknown';
  if (!byInterface[k]) byInterface[k] = [];
  byInterface[k].push(r);
});
Object.keys(byInterface).forEach(k => console.log(k + ':', byInterface[k].length));

console.log('');
console.log('=== All partial reqs ===');
par.forEach(r => {
  const desc = String(r.description).substring(0, 90);
  const sat = String(r.satisfied_by).substring(0, 60);
  const notes = String(r.notes).substring(0, 60);
  console.log(`${r.id} | ${r.interface} | ${r.category} | ${desc}`);
  console.log(`   satisfied_by: ${sat}`);
  console.log(`   notes: ${notes}`);
  console.log('');
});

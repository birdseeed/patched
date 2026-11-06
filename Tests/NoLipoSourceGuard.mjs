import assert from 'node:assert/strict';
import { readdirSync, readFileSync } from 'node:fs';
import { dirname, join, relative } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
function sources(directory) {
  return readdirSync(directory, { withFileTypes: true }).flatMap(entry => {
    const path = join(directory, entry.name);
    return entry.isDirectory() ? sources(path) : entry.name.endsWith('.swift') ? [path] : [];
  });
}

// Supplemental source audit, not a behavioural/no-CLT execution proof. /usr/bin/lipo is a
// Command Line Tools shim on a clean Mac, so productive source must never define, invoke or
// allowlist it.
const failures = [];
for (const path of sources(join(root, 'Sources'))) {
  const text = readFileSync(path, 'utf8');
  for (const [index, line] of text.split('\n').entries()) {
    if (line.includes('/usr/bin/lipo')) failures.push(`${relative(root, path)}:${index + 1}: ${line.trim()}`);
  }
}
assert.deepEqual(failures, [], 'Productive source must not define/invoke/allowlist the lipo shim');
console.log('source guard: no productive lipo references. Source audit is not clean-Mac proof.');

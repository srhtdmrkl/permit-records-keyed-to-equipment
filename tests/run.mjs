// Runs every test in a fresh in-process PostgreSQL (PGlite), no install needed.
// Core tests (tests/*.sql):     schema -> seed -> test file.
// App tests (tests/app/*.sql):  schema -> app rules -> helpers -> test file.
// Any error fails the test.

import { PGlite } from '@electric-sql/pglite';
import { readFileSync, readdirSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const read = (p) => readFileSync(join(root, p), 'utf8');
const sqlFiles = (dir) => readdirSync(join(root, dir))
  .filter((f) => f.endsWith('.sql') && !f.startsWith('_'))
  .sort()
  .map((f) => `${dir}/${f}`);

const suites = [
  { setup: [...sqlFiles('sql'), 'seed/p101_scenario.sql'], tests: sqlFiles('tests') },
  { setup: [...sqlFiles('sql'), ...sqlFiles('app/sql'), 'tests/app/_helpers.sql'], tests: sqlFiles('tests/app') },
];

let failed = 0;
let total = 0;
for (const { setup, tests } of suites) {
  for (const test of tests) {
    total++;
    const db = new PGlite();
    try {
      for (const f of setup) await db.exec(read(f));
      await db.exec(read(test));
      console.log(`ok    ${test}`);
    } catch (err) {
      failed++;
      console.log(`FAIL  ${test}\n      ${err.message}`);
    } finally {
      await db.close();
    }
  }
}

const { rows } = await (async () => {
  const db = new PGlite();
  const r = await db.query('SELECT version()');
  await db.close();
  return r;
})();
console.log(`\n${total - failed}/${total} passed on ${rows[0].version.split(' on ')[0]}`);
process.exit(failed ? 1 : 0);

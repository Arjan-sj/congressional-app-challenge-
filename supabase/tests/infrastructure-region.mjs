// Optional real-extract integration check. Creates only an ephemeral PGlite DB.
// Never reads hosted credentials or connects to a Supabase project.
import assert from 'node:assert/strict';
import { readFile, readdir } from 'node:fs/promises';
import { resolve, join } from 'node:path';
import { createDatabase } from './database.mjs';

if (process.argv.length !== 3) throw new Error('Usage: node infrastructure-region.mjs PATH_TO_PREPARED_SQL_DIRECTORY');
const directory = resolve(process.argv[2]);
const batches = (await readdir(directory)).filter(name => /^\d{5}\.sql$/.test(name)).sort();
assert(batches.length > 0, 'No numbered feature batches');
const db = await createDatabase();
try {
  for (const name of batches) await db.exec(await readFile(join(directory, name), 'utf8'));
  const count = async () => Number((await db.query('select count(*) as n from public.map_infrastructure')).rows[0].n);
  const before = await count();
  // Retry one batch and coverage registration; stable IDs must not duplicate data.
  await db.exec(await readFile(join(directory, batches[0]), 'utf8'));
  assert.equal(await count(), before);
  const coverage = await readFile(join(directory, 'coverage-after-review.sql'), 'utf8');
  await db.exec(coverage);
  await db.exec(coverage);
  const region = (await db.query('select id,feature_count,file_sha256 from public.infrastructure_import_regions')).rows[0];
  assert.equal(Number(region.feature_count), before);
  await db.exec('set role anon');
  const categories = ['sidewalk','walkingPath','crossing','bikePath','bikeLane'];
  const probes = [
    ['Schaumburg High School',42.021,-88.115,42.034,-88.097],
    ['Hoffman Estates area',42.05,-88.15,42.065,-88.13],
    ['Elk Grove Village area',41.995,-88.02,42.01,-88.00],
  ];
  const results = [];
  for (const [name,south,west,north,east] of probes) {
    let after = '', features = 0, requests = 0;
    do {
      const {rows} = await db.query('select public.infrastructure_viewport($1,$2,$3,$4,$5,17,$6) as data',
        [south,west,north,east,categories,after]);
      const p = rows[0].data;
      assert.equal(p.import_coverage, 'complete');
      assert.equal(p.fallback_required, false);
      assert(p.items.length <= 500);
      features += p.items.length; requests++;
      if (p.items.length < 500) break;
      assert.notEqual(after, p.items.at(-1).id);
      after = p.items.at(-1).id;
    } while (requests < 50);
    assert(requests < 50, 'Pagination did not terminate');
    assert(features > 0, `${name} unexpectedly empty`);
    results.push({name,features,databasePages:requests,overpassRequests:0});
  }
  console.log(JSON.stringify({localOnly:true,features:before,batches:batches.length,
    idempotency:'passed',region,probes:results},null,2));
} finally { await db.close(); }

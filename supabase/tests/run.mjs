// Local in-memory PostgreSQL + real PostGIS; never contacts hosted Supabase.
import { readFile } from 'node:fs/promises';
import { createDatabase } from './database.mjs';

const db = await createDatabase(console.log);
try {
  for (const name of ['nearest_school_association.sql', 'nationwide_map.sql', 'report_moderation.sql', 'school_districts.sql','moderator_accounts.sql', 'infrastructure_coverage.sql']) {
    const result = await db.exec(await readFile(new URL(`../checks/${name}`, import.meta.url), 'utf8'));
    console.log(`PASS ${name} (${result.length} statements)`);
  }
} catch (error) {
  console.error({ message: error.message, code: error.code, detail: error.detail, where: error.where });
  process.exitCode = 1;
} finally { await db.close(); }

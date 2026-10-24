// Local in-memory PostgreSQL + real PostGIS; never contacts hosted Supabase.
import { PGlite } from '@electric-sql/pglite';
import { postgis } from '@electric-sql/pglite-postgis';
import { readFile, readdir } from 'node:fs/promises';

const db = new PGlite({ extensions: { postgis } });
try {
  await db.exec(`
    create role anon;
    create role authenticated;
    create role service_role bypassrls;
    create schema auth;
    create table auth.users(id uuid primary key);
    create function auth.uid() returns uuid language sql stable as
      $$ select nullif(current_setting('request.jwt.claim.sub',true),'')::uuid $$;
    grant usage on schema auth to anon,authenticated,service_role;
    grant execute on function auth.uid() to anon,authenticated,service_role;
    create schema storage;
    create table storage.buckets(id text primary key,name text,public boolean,file_size_limit bigint,allowed_mime_types text[]);
    create table storage.objects(id uuid primary key default gen_random_uuid(),bucket_id text,name text,owner_id text);
    alter table storage.objects enable row level security;
    grant usage on schema storage to anon,authenticated,service_role;
    grant select,insert,update,delete on storage.objects to anon,authenticated,service_role;
    create function storage.foldername(text) returns text[] language sql immutable as
      $$ select string_to_array($1,'/') $$;
    create publication supabase_realtime;
    create function public.rls_auto_enable() returns event_trigger language plpgsql as $$ begin end $$;
  `);
  const dir = new URL('../migrations/', import.meta.url);
  for (const name of (await readdir(dir)).filter(n => n.endsWith('.sql')).sort()) {
    await db.exec((await readFile(new URL(name, dir), 'utf8')).replace(/^\uFEFF/, ''));
    console.log(`Applied ${name}`);
  }
  for (const name of ['nearest_school_association.sql', 'nationwide_map.sql', 'report_moderation.sql']) {
    const result = await db.exec(await readFile(new URL(`../checks/${name}`, import.meta.url), 'utf8'));
    console.log(`PASS ${name} (${result.length} statements)`);
  }
} catch (error) {
  console.error({ message: error.message, code: error.code, detail: error.detail, where: error.where });
  process.exitCode = 1;
} finally { await db.close(); }

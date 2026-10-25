import { PGlite } from '@electric-sql/pglite';
import { postgis } from '@electric-sql/pglite-postgis';
import { readFile, readdir } from 'node:fs/promises';

export async function createDatabase(log = () => {}) {
  const db = new PGlite({ extensions: { postgis } });
  try {
    await db.exec(`
      create role anon;
      create role authenticated;
      create role service_role bypassrls;
      create schema auth;
      create table auth.users(id uuid primary key,email text,email_confirmed_at timestamptz,
        banned_until timestamptz,deleted_at timestamptz);
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
      create function storage.foldername(text) returns text[] language sql immutable as $$ select string_to_array($1,'/') $$;
      create schema supabase_migrations;
      create table supabase_migrations.schema_migrations(version text primary key,name text);
      create publication supabase_realtime;
      create function public.rls_auto_enable() returns event_trigger language plpgsql as $$ begin end $$;
    `);
    const dir = new URL('../migrations/', import.meta.url);
    for (const name of (await readdir(dir)).filter(n => n.endsWith('.sql')).sort()) {
      await db.exec((await readFile(new URL(name, dir), 'utf8')).replace(/^\uFEFF/, ''));
      await db.query('insert into supabase_migrations.schema_migrations values($1,$2)',[name.split('_')[0],name]);
      log(`Applied ${name}`);
    }
    return db;
  } catch(error) { await db.close(); throw error; }
}

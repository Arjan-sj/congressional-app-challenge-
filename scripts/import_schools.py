"""NCES EDGE synchronization. Python standard library; credentials stay server-side.

Defaults were verified against the official service directory on 2026-10-20.
Public IDs use NCESSCH; private IDs use PPIN (not the same source schema).
"""
import argparse
import csv
import datetime as dt
import json
import hashlib
import math
import os
from pathlib import Path
import random
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

from nces_districts import load_district_catalog, normalize_school, district_payload, normalize_id

BASE = 'https://nces.ed.gov/opengis/rest/services/K12_School_Locations'
SOURCES = {'public': ('2425', 'NCESSCH'), 'private': ('2324', 'PPIN')}


def request(url, payload=None, headers=None):
    data = None if payload is None else json.dumps(payload).encode()
    for attempt in range(3):
        try:
            with urllib.request.urlopen(urllib.request.Request(url, data=data, headers=headers or {}), timeout=60) as response:
                raw = response.read()
                result = json.loads(raw) if raw else None
            if isinstance(result, dict) and result.get('error'):
                raise ValueError('Source returned an error: ' + str(result['error']))
            return result
        except (urllib.error.URLError, TimeoutError) as error:
            if isinstance(error, urllib.error.HTTPError) and error.code not in (429, 500, 502, 503, 504):
                raise
            if attempt == 2:
                raise
            retry = error.headers.get('Retry-After', '') if isinstance(error, urllib.error.HTTPError) else ''
            if retry.isdigit() and int(retry) > 120:
                raise RuntimeError('Provider requested a long cooldown; resume later') from error
            time.sleep(int(retry) if retry.isdigit() else 2 ** attempt + random.random())


def normalize(row, kind, year, seen, districts=None):
    identifier = str(row.get(SOURCES[kind][1]) or '').strip()
    if kind == 'public':
        identifier = normalize_id(row.get('NCESSCH'),12)
    name = str(row.get('NAME') or '').strip()
    if not identifier or not name:
        raise ValueError('Missing identifier/name')
    # Preserve leading zeros; never spatially merge co-located schools.
    if not identifier.isalnum() or len(identifier) > 16:
        raise ValueError('Invalid identifier: ' + identifier)
    lat, lon = float(row['LAT']), float(row['LON'])
    if not math.isfinite(lat) or not math.isfinite(lon) or not (-90 <= lat <= 90 and -180 <= lon <= 180) or (lat == 0 and lon == 0):
        raise ValueError('Invalid coordinates: ' + identifier)
    key = (kind, identifier)
    if key in seen:
        raise ValueError('Duplicate identifier: ' + identifier)
    seen.add(key)
    result = dict(id=identifier if kind == 'public' else 'nces-private:' + identifier,
                source='nces-' + kind, source_id=identifier, name=name,
                latitude=lat, longitude=lon, address=row.get('STREET'),
                city=row.get('CITY'), state=row.get('STATE'), zip_code=row.get('ZIP'),
                classification=kind, source_dataset='EDGE_GEOCODE_' + kind.upper() + 'SCH_' + year,
                source_year=str(row.get('SCHOOLYEAR') or year), synced_at=dt.datetime.now(dt.timezone.utc).isoformat())
    if kind == 'public' and districts is not None:
        school = normalize_school(row, year)
        district = districts.get(school['leaid'])
        if not district or district['source_year'] != school['source_year'] or district['metadata']['opstfips'] != school['opstfips']:
            raise ValueError('Missing/incompatible official district for school ' + identifier)
        result.update(district_id='nces-lea:' + district['leaid'], district=district['name'],
                      state=school['state'],source_year=school['source_year'],
                      district_source_year=school['source_year'], district_source_dataset=school['source_dataset'],
                      district_link_metadata=dict(ncessch=school['ncessch'],school_state=school['state'],
                        school_opstfips=school['opstfips'],school_source_url=school['source_url'],
                        district_source_url=district['source_url']),
                      _district_fact=district_payload(district))
    return result


def source_rows(kind, year, csv_path=None, max_records=None):
    if csv_path:
        with open(csv_path, encoding='utf-8-sig', newline='') as handle:
            yield from csv.DictReader(handle)
        return
    layer = BASE + '/EDGE_GEOCODE_' + kind.upper() + 'SCH_' + year + '/MapServer/0'
    metadata = request(layer + '?f=json')
    required = {SOURCES[kind][1], 'NAME', 'LAT', 'LON', 'SCHOOLYEAR'}
    if kind == 'public':
        required |= {'LEAID', 'OPSTFIPS'}
    if not required.issubset({f['name'] for f in metadata['fields']}):
        raise ValueError('Source schema changed; inspect fields before import')
    ids = request(layer + '/query?f=json&where=1%3D1&returnIdsOnly=true')['objectIds']
    ids = sorted(ids)
    if max_records:
        ids = ids[:max_records]
    fields = ','.join([SOURCES[kind][1], 'NAME', 'STREET', 'CITY', 'STATE', 'ZIP', 'LAT', 'LON', 'SCHOOLYEAR'] +
                      (['LEAID','OPSTFIPS'] if kind == 'public' else []))
    for offset in range(0, len(ids), 1000):
        params = urllib.parse.urlencode(dict(f='json', objectIds=','.join(map(str, ids[offset:offset + 1000])), outFields=fields, returnGeometry='false'))
        result = request(layer + '/query?' + params)
        if result.get('exceededTransferLimit') or len(result['features']) != len(ids[offset:offset + 1000]):
            raise ValueError('Incomplete NCES page; no silent truncation allowed')
        yield from (feature['attributes'] for feature in result['features'])


def batch_payload(rows, reviewed_by, approved_school_ids=None):
    districts = {r['_district_fact']['id']: r['_district_fact'] for r in rows if '_district_fact' in r}
    clean = [{k:v for k,v in row.items() if k != '_district_fact'} for row in rows]
    digest = hashlib.sha256(json.dumps({'schools':clean,'districts':list(districts.values()),
                                        'approved_school_ids':approved_school_ids or []},sort_keys=True).encode()).hexdigest()
    return dict(p_schools=clean,p_districts=list(districts.values()),p_reviewed_by=reviewed_by,
                p_plan_sha256=digest,p_approved_school_ids=approved_school_ids or [])


def sql_batch(rows, reviewed_by=None, approved_school_ids=None):
    if reviewed_by is None and any('_district_fact' in row for row in rows):
        raise ValueError('District-bearing imports require reviewed RPC batches')
    if reviewed_by is not None:
        payload = batch_payload(rows, reviewed_by, approved_school_ids)
        literal = lambda value: "'" + json.dumps(value,ensure_ascii=True).replace("'", "''") + "'::jsonb"
        return ("select public.sync_nces_school_batch(" + literal(payload['p_schools']) + ',' + literal(payload['p_districts']) +
                ",'" + reviewed_by.replace("'", "''") + "','" + payload['p_plan_sha256'] +
                "',array(select jsonb_array_elements_text(" + literal(payload['p_approved_school_ids']) + ')));')
    # Typed recordset keeps SQL literals escaped; IDs preserve existing report FKs.
    encoded = json.dumps(rows, ensure_ascii=True).replace("'", "''")
    columns = ['id', 'source', 'source_id', 'name', 'latitude', 'longitude', 'address', 'city', 'state', 'zip_code', 'classification', 'source_dataset', 'source_year', 'synced_at']
    types = {c: 'text' for c in columns}
    types.update(latitude='float8', longitude='float8', synced_at='timestamptz')
    return ('insert into public.schools (' + ','.join(columns) + ') select ' + ','.join(columns) +
            " from jsonb_to_recordset('" + encoded + "'::jsonb) as r(" + ','.join(c + ' ' + types[c] for c in columns) +
            ') on conflict(id) do update set ' + ','.join(c + '=excluded.' + c for c in columns if c != 'id') + ';')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--kind', choices=['public', 'private', 'both'], default='both')
    parser.add_argument('--dry-run', action='store_true')
    parser.add_argument('--csv', help='Use an already downloaded official CSV (single kind only)')
    parser.add_argument('--max-records', type=int, help='Limit source records for a smoke test')
    parser.add_argument('--batch-size', type=int, default=500)
    parser.add_argument('--sql-dir', help='Prepare SQL batches for trusted database tooling instead of REST')
    parser.add_argument('--errors', default='private/nces-import-errors.jsonl')
    parser.add_argument('--district-csv', help='Official same-year public LEA catalog CSV')
    parser.add_argument('--district-cache', default='private/nces-district-cache')
    parser.add_argument('--reviewed-by', help='Operator who verified the official source data')
    parser.add_argument('--confirm-project', help='Exact Supabase project reference for a live import')
    parser.add_argument('--approve-school-ids', help='JSON file listing individually reviewed district transfers/text conflicts')
    args = parser.parse_args()
    if args.csv and args.kind == 'both':
        parser.error('--csv requires --kind public or private')
    if args.dry_run and args.sql_dir:
        parser.error('Choose --dry-run or prepared --sql-dir batches, not both')
    if args.max_records is not None and args.max_records < 1:
        parser.error('--max-records must be positive')
    if not 1 <= args.batch_size <= 500:
        parser.error('batch-size must be 1..500')
    url, key = os.getenv('SUPABASE_URL'), os.getenv('SUPABASE_SERVICE_ROLE_KEY')
    if not args.dry_run and not args.sql_dir and not (url and key):
        parser.error('Set server-only SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY, or use --dry-run / --sql-dir')
    if not args.dry_run and (not args.reviewed_by or len(args.reviewed_by.strip()) < 3):
        parser.error('A --reviewed-by operator is required for reviewed writes/prepared SQL')
    if not args.dry_run and not args.sql_dir:
        target = urllib.parse.urlparse(url)
        if (not args.confirm_project or target.scheme != 'https' or target.username or target.password
                or target.query or target.fragment or target.path not in ('','/')
                or target.hostname != args.confirm_project + '.supabase.co'):
            parser.error('--confirm-project must match the exact hosted Supabase URL')
    approved = []
    if args.approve_school_ids:
        approved = json.loads(Path(args.approve_school_ids).read_text(encoding='utf-8'))
        if not isinstance(approved,list) or not all(isinstance(value,str) for value in approved):
            parser.error('--approve-school-ids must be a JSON array of reviewed existing school IDs')
    district_catalog = None
    if args.kind != 'private':
        district_catalog, _ = load_district_catalog(SOURCES['public'][0], args.district_cache, args.district_csv)
    # Check newer official releases each run, fail rather than silently import stale data.
    services = request(BASE + '?f=json')['services'] if not args.csv else []
    names = [service['name'].split('/')[-1] for service in services]
    seen, batch, valid, errors, batch_index = set(), [], 0, 0, 0
    error_path = Path(args.errors)
    error_path.parent.mkdir(parents=True, exist_ok=True)
    def flush():
        nonlocal batch_index
        if not batch:
            return
        if args.sql_dir:
            directory = Path(args.sql_dir)
            directory.mkdir(parents=True, exist_ok=True)
            (directory / f'{batch_index:05}.sql').write_text(sql_batch(batch,args.reviewed_by,approved), encoding='utf-8')
        elif not args.dry_run:
            request(url.rstrip('/') + '/rest/v1/rpc/sync_nces_school_batch', batch_payload(batch,args.reviewed_by,approved),
                    {'apikey': key, 'Authorization': 'Bearer ' + key, 'Content-Type': 'application/json'})
        batch_index += 1
        print(json.dumps(dict(valid=valid, invalid=errors, batches=batch_index, dry_run=args.dry_run)), flush=True)
        batch.clear()
    with error_path.open('w', encoding='utf-8') as failures:
        for kind in (SOURCES if args.kind == 'both' else [args.kind]):
            year = SOURCES[kind][0]
            available = sorted(n for n in names if n.startswith('EDGE_GEOCODE_' + kind.upper() + 'SCH_'))
            if available and available[-1] != 'EDGE_GEOCODE_' + kind.upper() + 'SCH_' + year:
                raise ValueError('New source release found: ' + available[-1] + '; inspect and update schema mapping')
            for index, row in enumerate(source_rows(kind, year, args.csv, args.max_records)):
                if args.max_records and index >= args.max_records:
                    break
                try:
                    batch.append(normalize(row, kind, year, seen, district_catalog if kind == 'public' else None))
                    valid += 1
                except (ValueError, KeyError, TypeError) as error:
                    errors += 1
                    failures.write(json.dumps(dict(kind=kind, row=index + 1, error=str(error))) + '\n')
                if len(batch) >= args.batch_size:
                    flush()
        flush()
    if not args.dry_run:
        if args.sql_dir:
            (Path(args.sql_dir) / '99999_aliases.sql').write_text('select public.sync_known_school_aliases();', encoding='utf-8')
        else:
            request(url.rstrip('/') + '/rest/v1/rpc/sync_known_school_aliases', {},
                    {'apikey': key, 'Authorization': 'Bearer ' + key, 'Content-Type': 'application/json'})
    print(json.dumps(dict(complete=True, valid=valid, invalid=errors, batches=batch_index)))
    return 1 if errors else 0


if __name__ == '__main__':
    sys.exit(main())

"""Import a SELECTIVELY FILTERED regional osmium GeoJSON sequence into PostGIS.

See docs/NATIONWIDE_MAP.md for extraction commands. Never feed a nationwide extract
to Flutter. Refresh upserts stable OSM type/id/category identifiers. No auto-delete.
"""
import argparse
import datetime as dt
import json
import math
import os
from pathlib import Path
import sys
from import_schools import request


class CrossingIndex:
    def __init__(self):
        self.cells = {}

    def add(self, point):
        key = (math.floor(point[0] * 10000), math.floor(point[1] * 10000))
        self.cells.setdefault(key, []).append(point)

    def touches(self, geometry):
        points = geometry['coordinates'] if geometry['type'] == 'LineString' else []
        for lon, lat in points:
            x, y = math.floor(lon * 10000), math.floor(lat * 10000)
            for dx in range(-2, 3):
                for dy in range(-2, 3):
                    for other_lon, other_lat in self.cells.get((x + dx, y + dy), []):
                        if math.hypot((lon - other_lon) * math.cos(lat * math.pi / 180), lat - other_lat) < .00012:
                            return True
        return False


def classify(tags):
    positive = lambda value: value and value not in ('no', 'none', 'separate', 'unknown')
    highway = tags.get('highway')
    result = []
    if tags.get('access') == 'private':
        return result
    if highway == 'crossing' or highway == 'footway' and tags.get('footway') == 'crossing':
        result.append('crossing')
    if tags.get('foot') != 'no':
        if highway == 'footway' and tags.get('footway') == 'sidewalk' or any(positive(tags.get(key)) for key in ('sidewalk', 'sidewalk:left', 'sidewalk:right', 'sidewalk:both')):
            result.append('sidewalk')
        elif highway in ('footway', 'path', 'pedestrian') and tags.get('footway') != 'crossing':
            result.append('walkingPath')
    if tags.get('bicycle') != 'no':
        cycle = [tags.get(key) for key in ('cycleway', 'cycleway:left', 'cycleway:right', 'cycleway:both')]
        if highway == 'cycleway' or highway == 'path' and tags.get('bicycle') == 'designated' or any(v in ('track', 'opposite_track') for v in cycle):
            result.append('bikePath')
        if any(v in ('lane', 'opposite_lane', 'shared_lane', 'share_busway') for v in cycle):
            result.append('bikeLane')
    return result


def valid_geometry(geometry):
    if geometry.get('type') not in ('Point', 'LineString', 'MultiLineString', 'MultiPoint'):
        return False
    def check(coords):
        if len(coords) >= 2 and isinstance(coords[0], (int, float)):
            return all(math.isfinite(n) for n in coords) and -180 <= coords[0] <= 180 and -90 <= coords[1] <= 90
        return bool(coords) and all(check(c) for c in coords)
    return check(geometry.get('coordinates', []))


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('file', help='osmium export GeoJSON sequence with @id type_id properties')
    p.add_argument('--region', required=True)
    p.add_argument('--source-updated-at', required=True, help='Extract replication timestamp, ISO-8601')
    p.add_argument('--dry-run', action='store_true')
    p.add_argument('--sql-dir', help='Prepare SQL batches for trusted database tooling without a local key')
    p.add_argument('--batch-size', type=int, default=300)
    args = p.parse_args()
    dt.datetime.fromisoformat(args.source_updated_at.replace('Z', '+00:00'))
    if not 1 <= args.batch_size <= 1000:
        p.error('batch-size must be 1..1000')
    url, key = os.getenv('SUPABASE_URL'), os.getenv('SUPABASE_SERVICE_ROLE_KEY')
    if not args.dry_run and not args.sql_dir and not (url and key):
        p.error('Server-only SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY required')
    seen, batch, valid, skipped, batch_index = set(), [], 0, 0, 0
    crossing_nodes = CrossingIndex()
    def flush():
        nonlocal batch_index
        if args.sql_dir:
            directory = Path(args.sql_dir)
            directory.mkdir(parents=True, exist_ok=True)
            payload = json.dumps(batch, separators=(',', ':'), ensure_ascii=True).replace("'", "''")
            sql = """insert into public.map_infrastructure(id,osm_id,category,geometry,tags,source_region,source_updated_at)
select id,osm_id,category,extensions.st_setsrid(extensions.st_geomfromgeojson(geometry),4326),tags,source_region,source_updated_at
from jsonb_to_recordset('""" + payload + """'::jsonb) as r(id text,osm_id text,category text,geometry jsonb,tags jsonb,source_region text,source_updated_at timestamptz)
on conflict(id) do update set geometry=excluded.geometry,tags=excluded.tags,source_region=excluded.source_region,source_updated_at=excluded.source_updated_at,synced_at=now();
"""
            (directory / f'{batch_index:05}.sql').write_text(sql, encoding='utf-8')
        elif not args.dry_run:
            request(url.rstrip('/') + '/rest/v1/map_infrastructure?on_conflict=id', batch,
                    {'apikey': key, 'Authorization': 'Bearer ' + key, 'Content-Type': 'application/json', 'Prefer': 'resolution=merge-duplicates,return=minimal'})
        print(json.dumps(dict(imported=valid, skipped=skipped, dry_run=args.dry_run)), flush=True)
        batch_index += 1
        batch.clear()
    with Path(args.file).open(encoding='utf-8') as source:
        for line_number, line in enumerate(source, 1):
            if not line.strip():
                continue
            try:
                feature = json.loads(line.lstrip('\x1e'))
                tags, geometry = feature['properties'], feature['geometry']
                osm_id = str(tags.get('@id') or feature.get('id') or '')
                if not osm_id or not osm_id.startswith(('n', 'w', 'r')):
                    raise ValueError('Stable OSM type/id missing; use osmium --add-unique-id=type_id')
                if not valid_geometry(geometry):
                    skipped += 1
                    continue
                # Export nodes before ways. Keep way-only crossings; suppress a
                # connecting way only when a nearby crossing node represents it.
                categories = classify(tags)
                if geometry['type'] == 'Point' and tags.get('highway') == 'crossing':
                    crossing_nodes.add(geometry['coordinates'])
                if osm_id.startswith('w') and tags.get('footway') == 'crossing' and crossing_nodes.touches(geometry):
                    categories = [c for c in categories if c != 'crossing']
                for category in categories:
                    identifier = osm_id + '/' + category
                    if identifier in seen:
                        continue
                    seen.add(identifier)
                    kept = {k: str(v) for k, v in tags.items() if k in ('name', 'highway', 'footway', 'crossing', 'crossing:signals', 'crossing:markings', 'wheelchair', 'tactile_paving', 'bicycle', 'foot')}
                    batch.append(dict(id=identifier, osm_id=osm_id, category=category,
                                      geometry=geometry, tags=kept, source_region=args.region,
                                      source_updated_at=args.source_updated_at))
                    valid += 1
                    if len(batch) >= args.batch_size:
                        flush()
            except (ValueError, KeyError, TypeError) as error:
                print(f'Invalid feature at line {line_number}: {error}', file=sys.stderr)
                return 1
    if batch:
        flush()
    print(json.dumps(dict(complete=True, imported=valid, skipped=skipped)))
    return 0


if __name__ == '__main__':
    sys.exit(main())

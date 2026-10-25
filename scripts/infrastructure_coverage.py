"""Validate bounded extraction provenance; SQL is prepared, never executed here."""
import datetime as dt
import hashlib
import json
import math
from pathlib import Path
from urllib.parse import urlparse

CATEGORIES = {'sidewalk', 'walkingPath', 'crossing', 'bikePath', 'bikeLane'}


def coverage_record(file, manifest_file, region, timestamp, count, fresh_days=14):
    m = json.loads(Path(manifest_file).read_text(encoding='utf-8'))
    bounds = m.get('bounds', [])
    if (m.get('version') != 1 or m.get('complete') is not True or len(bounds) != 4
            or not all(isinstance(v, (int, float)) and math.isfinite(v) for v in bounds)
            or not -180 <= bounds[0] < bounds[2] <= 180
            or not -85 <= bounds[1] < bounds[3] <= 85
            or bounds[2]-bounds[0] > 2 or bounds[3]-bounds[1] > 2):
        raise ValueError('Complete, bounded regional export manifest required')
    source = urlparse(m.get('source_url', ''))
    if source.scheme != 'https' or source.hostname != 'download.geofabrik.de' or source.username or source.password:
        raise ValueError('Official Geofabrik extract URL required')
    if m.get('source_updated_at') != timestamp or set(m.get('categories', [])) != CATEGORIES:
        raise ValueError('Source timestamp/categories do not match export')
    with Path(file).open('rb') as data:
        checksum = hashlib.file_digest(data, 'sha256').hexdigest()
    if checksum != m.get('file_sha256'):
        raise ValueError('Export checksum mismatch; incomplete/changed file')
    source_time = dt.datetime.fromisoformat(timestamp.replace('Z', '+00:00'))
    if source_time.tzinfo is None or source_time > dt.datetime.now(dt.timezone.utc) + dt.timedelta(minutes=5):
        raise ValueError('Invalid source time')
    if not 1 <= fresh_days <= 30:
        raise ValueError('Freshness must be 1..30 days')
    west, south, east, north = bounds
    return dict(id=region, bounds={'type':'Polygon','coordinates':[[[west,south],[east,south],
        [east,north],[west,north],[west,south]]]}, categories=sorted(CATEGORIES),
        source_url=m['source_url'], source_updated_at=timestamp,
        fresh_until=(source_time + dt.timedelta(days=fresh_days)).isoformat(),
        feature_count=count, file_sha256=checksum)


def coverage_sql(record):
    payload = json.dumps(record, separators=(',', ':')).replace("'", "''")
    return """-- Apply ONLY after all feature batches succeed and counts/provenance are reviewed.
insert into public.infrastructure_import_regions(id,bounds,categories,source_url,source_updated_at,fresh_until,feature_count,file_sha256)
select id,extensions.st_setsrid(extensions.st_geomfromgeojson(bounds),4326),categories,source_url,source_updated_at,fresh_until,feature_count,file_sha256
from jsonb_to_record('""" + payload + """'::jsonb) as r(id text,bounds jsonb,categories text[],source_url text,source_updated_at timestamptz,fresh_until timestamptz,feature_count bigint,file_sha256 text)
on conflict(id) do update set bounds=excluded.bounds,categories=excluded.categories,source_url=excluded.source_url,
source_updated_at=excluded.source_updated_at,fresh_until=excluded.fresh_until,feature_count=excluded.feature_count,
file_sha256=excluded.file_sha256,imported_at=now();
"""

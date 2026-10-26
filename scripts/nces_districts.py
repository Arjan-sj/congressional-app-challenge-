"""Official NCES district facts; standard library and no database writes.

IDs are taken from explicit source fields. A school's NCESSCH prefix is never
used to invent or override its current LEAID relationship.
"""
import concurrent.futures
import csv
import hashlib
import json
import math
from pathlib import Path
import random
import re
import time
import urllib.error
import urllib.parse
import urllib.request

BASE = 'https://nces.ed.gov/opengis/rest/services/K12_School_Locations'
DEFAULT_YEAR = '2425'


def normalize_year(value):
    value = str(value or '').strip()
    if re.fullmatch(r'\d{4}', value):
        start, end = 2000 + int(value[:2]), 2000 + int(value[2:])
    else:
        match = re.fullmatch(r'(20\d{2})\s*[-/\u2013]\s*(20\d{2})', value)
        if not match:
            raise ValueError('A verified consecutive NCES school year is required')
        start, end = map(int, match.groups())
    if end != start + 1:
        raise ValueError('Inconsistent NCES school year: ' + value)
    return f'{start:04}-{end:04}'


def year_code(value):
    year = normalize_year(value)
    return year[2:4] + year[7:9]


def normalize_id(value, width):
    """Preserve source strings exactly; fixed-width numeric fields may be padded."""
    if isinstance(value, bool) or value is None:
        raise ValueError('Missing/invalid NCES identifier')
    if isinstance(value, int) or (isinstance(value, float) and math.isfinite(value) and value.is_integer()):
        text = str(int(value)).zfill(width)
    else:
        text = str(value).strip()
    if not re.fullmatch(r'\d{' + str(width) + r'}', text) or int(text) == 0:
        raise ValueError('Invalid fixed-width NCES identifier: ' + text)
    return text


def _state(value):
    text = str(value or '').strip().upper()
    if not re.fullmatch(r'[A-Z]{2}', text):
        raise ValueError('Missing/invalid physical state')
    return text


def _opstfips(value):
    if isinstance(value, str):
        value = value.strip()
        if value.isdigit() and len(value) < 2:
            value = int(value)
    return normalize_id(value, 2)


def source_url(kind, year=DEFAULT_YEAR):
    suffix = 'PUBLICSCH' if kind == 'schools' else 'PUBLICLEA'
    return f'{BASE}/EDGE_GEOCODE_{suffix}_{year_code(year)}/MapServer/0'


def normalize_school(row, year=DEFAULT_YEAR):
    normalized_year = normalize_year(row.get('SCHOOLYEAR'))
    if normalized_year != normalize_year(year):
        raise ValueError('Official school row source-year mismatch')
    return dict(ncessch=normalize_id(row.get('NCESSCH'), 12),
                leaid=normalize_id(row.get('LEAID'), 7), state=_state(row.get('STATE')),
                opstfips=_opstfips(row.get('OPSTFIPS')), source_year=normalized_year,
                source_dataset='EDGE_GEOCODE_PUBLICSCH_' + year_code(year),
                source_url=source_url('schools', year))


def normalize_district(row, year=DEFAULT_YEAR):
    normalized_year = normalize_year(row.get('SCHOOLYEAR'))
    if normalized_year != normalize_year(year):
        raise ValueError('Official district row source-year mismatch')
    name = str(row.get('NAME') or '').strip()
    if not name or len(name) > 500:
        raise ValueError('Missing/invalid official district name')
    return dict(leaid=normalize_id(row.get('LEAID'), 7), name=name,
                state=_state(row.get('STATE')), source_year=normalized_year,
                source_dataset='EDGE_GEOCODE_PUBLICLEA_' + year_code(year),
                source_url=source_url('districts', year),
                metadata={'opstfips': _opstfips(row.get('OPSTFIPS')),
                          'street': str(row.get('STREET') or '').strip(),
                          'city': str(row.get('CITY') or '').strip(),
                          'zip_code': str(row.get('ZIP') or '').strip()})


def district_payload(district):
    return dict(id='nces-lea:' + district['leaid'], nces_lea_id=district['leaid'],
                name=district['name'], state=district['state'],
                source_dataset=district['source_dataset'], source_year=district['source_year'],
                source_url=district['source_url'], metadata=district['metadata'])


def request(url, payload=None, headers=None):
    data = None if payload is None else json.dumps(payload).encode('utf-8')
    for attempt in range(3):
        try:
            req = urllib.request.Request(url, data=data, headers=headers or {})
            with urllib.request.urlopen(req, timeout=60) as response:
                raw = response.read()
                result = json.loads(raw) if raw else None
            if isinstance(result, dict) and result.get('error'):
                raise ValueError('Official source returned an error: ' + str(result['error']))
            return result
        except (urllib.error.URLError, TimeoutError) as error:
            if isinstance(error, urllib.error.HTTPError) and error.code not in (429, 500, 502, 503, 504):
                raise
            if attempt == 2:
                raise
            retry = error.headers.get('Retry-After', '') if isinstance(error, urllib.error.HTTPError) else ''
            if retry.isdigit() and int(retry) > 120:
                raise RuntimeError('NCES requested a long cooldown; resume later') from error
            time.sleep(int(retry) if retry.isdigit() else 2 ** attempt + random.random())


def _digest(value):
    return hashlib.sha256(json.dumps(value, ensure_ascii=True, sort_keys=True, separators=(',', ':')).encode()).hexdigest()


def _official_rows(kind, year, requester=request):
    layer = source_url(kind, year)
    metadata = requester(layer + '?f=json')
    required = {'LEAID', 'STATE', 'OPSTFIPS', 'SCHOOLYEAR'} | ({'NCESSCH'} if kind == 'schools' else {'NAME'})
    fields = {field['name'] for field in metadata['fields']}
    if not required <= fields:
        raise ValueError('NCES source schema changed; required fields are missing')
    oid = next((field['name'] for field in metadata['fields'] if field['type'] == 'esriFieldTypeOID'), None)
    if not oid:
        raise ValueError('NCES object ID field is missing')
    ids = sorted(requester(layer + '/query?f=json&where=1%3D1&returnIdsOnly=true')['objectIds'])
    if len(ids) != len(set(ids)):
        raise ValueError('Duplicate NCES source object IDs')
    selected_fields = required | {oid}
    if kind == 'districts':
        selected_fields |= fields & {'STREET', 'CITY', 'ZIP'}
    pages = [ids[offset:offset + 1000] for offset in range(0, len(ids), 1000)]

    def fetch_page(page):
        params = urllib.parse.urlencode(dict(f='json', objectIds=','.join(map(str, page)),
                                            outFields=','.join(sorted(selected_fields)), returnGeometry='false'))
        result = requester(layer + '/query?' + params)
        rows = [feature['attributes'] for feature in result['features']]
        if result.get('exceededTransferLimit') or len(rows) != len(page) or {row[oid] for row in rows} != set(page):
            raise ValueError('Incomplete NCES page; refusing a truncated source')
        return rows

    with concurrent.futures.ThreadPoolExecutor(max_workers=4) as executor:
        rows = [row for page in executor.map(fetch_page, pages) for row in page]
    if not rows:
        raise ValueError('Official NCES source returned no rows')
    return rows


def _rows(kind, year, csv_path=None, cache_dir=None, requester=request):
    layer = source_url(kind, year)
    if csv_path:
        path = Path(csv_path)
        with path.open(encoding='utf-8-sig', newline='') as handle:
            rows = list(csv.DictReader(handle))
        return rows, {'url': layer, 'input': str(path), 'sha256': hashlib.sha256(path.read_bytes()).hexdigest(),
                      'mode': 'operator-supplied-official-csv', 'rows': len(rows)}
    path = Path(cache_dir) / f'nces-{kind}-{year_code(year)}.json' if cache_dir else None
    if path and path.exists():
        envelope = json.loads(path.read_text(encoding='utf-8'))
        if envelope.get('source_url') != layer or envelope.get('sha256') != _digest(envelope.get('rows')):
            raise ValueError('NCES source cache identity/checksum mismatch')
        rows = envelope['rows']
    else:
        rows = _official_rows(kind, year, requester)
        if path:
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(json.dumps({'source_url': layer, 'sha256': _digest(rows), 'rows': rows}), encoding='utf-8')
    return rows, {'url': layer, 'sha256': _digest(rows), 'mode': 'official-https-catalog', 'rows': len(rows)}


def _index(rows, normalizer, key, year):
    if not rows:
        raise ValueError('Official NCES catalog is empty')
    result = {}
    for row in rows:
        item = normalizer(row, year)
        if item[key] in result:
            raise ValueError('Duplicate/conflicting official identifier: ' + item[key])
        result[item[key]] = item
    return result


def load_district_catalog(year=DEFAULT_YEAR, cache_dir=None, district_csv=None, requester=request):
    rows, manifest = _rows('districts', year, district_csv, cache_dir, requester)
    return _index(rows, normalize_district, 'leaid', year), manifest


def load_catalog(year=DEFAULT_YEAR, cache_dir=None, school_csv=None, district_csv=None, requester=request):
    rows, school_manifest = _rows('schools', year, school_csv, cache_dir, requester)
    schools = _index(rows, normalize_school, 'ncessch', year)
    districts, district_manifest = load_district_catalog(year, cache_dir, district_csv, requester)
    return schools, districts, {'source_year': normalize_year(year), 'schools': school_manifest, 'districts': district_manifest}

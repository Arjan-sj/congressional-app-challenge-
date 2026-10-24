"""Preview and explicitly review an exact-ID NCES school/district backfill.

The default operation only reads official sources and public school records.
Applying a plan requires its reviewed SHA-256, exact target project confirmation,
an operator name and a server-side key. No source file or plan is modified during
apply; batch checkpoints advance only after a committed RPC acknowledges rows.
"""
import argparse
import collections
import datetime as dt
import hashlib
import json
import os
from pathlib import Path
import re
import sys
import tempfile
import urllib.error
import urllib.parse

from nces_districts import DEFAULT_YEAR, load_catalog, normalize_id, normalize_year, request

FORMAT = 'saferoutes-school-district-plan-v1'
EXPECTED_FIELDS = ('classification', 'canonical_id', 'source', 'source_id', 'source_dataset',
                   'source_year', 'state', 'district', 'district_id', 'district_source_year')
BASE_FIELDS = ('id', 'classification', 'canonical_id', 'source', 'source_id', 'source_dataset',
               'source_year', 'state', 'district')


def project_identity(url):
    parsed = urllib.parse.urlparse(url)
    match = re.fullmatch(r'([a-z]{20})\.supabase\.co', parsed.hostname or '')
    if parsed.scheme != 'https' or not match or parsed.username or parsed.password or parsed.query or parsed.fragment or parsed.path not in ('', '/'):
        raise ValueError('Use the exact HTTPS Supabase project origin, without credentials or paths')
    return match.group(1), parsed.scheme + '://' + parsed.netloc


def _headers(key):
    return {'apikey': key, 'Authorization': 'Bearer ' + key, 'Content-Type': 'application/json'}


def fetch_target_schools(url, public_key, requester=request, page_size=1000):
    """Public directory only. Keyset paging prevents the API row cap hiding data."""
    _, origin = project_identity(url)
    fields = list(BASE_FIELDS)
    probe = origin + '/rest/v1/schools?select=district_id&limit=1'
    try:
        requester(probe, headers=_headers(public_key))
        fields += ['district_id', 'district_source_year']
    except urllib.error.HTTPError as error:
        body = error.read()
        error.close()
        try:
            detail = json.loads(body)
        except (ValueError, UnicodeDecodeError):
            raise error
        # Only the genuine pre-migration missing-column error permits fallback.
        if error.code != 400 or detail.get('code') not in ('42703', 'PGRST204') or 'district_id' not in detail.get('message', ''):
            raise error
    rows, after = [], None
    while True:
        params = {'select': ','.join(fields), 'order': 'id.asc', 'limit': page_size}
        if after is not None:
            params['id'] = 'gt.' + after
        page = requester(origin + '/rest/v1/schools?' + urllib.parse.urlencode(params), headers=_headers(public_key))
        if not isinstance(page, list) or len(page) > page_size:
            raise ValueError('Unexpected school directory response')
        ids = [row.get('id') for row in page]
        if any(not isinstance(identifier, str) or not identifier for identifier in ids) or ids != sorted(set(ids)) or (ids and after is not None and ids[0] <= after):
            raise ValueError('Unstable/duplicate school directory pagination')
        rows.extend(page)
        if len(page) < page_size:
            break
        after = page[-1]['id']
    return rows


def assess_school(target, schools, districts):
    """Return a disposition plus an exact expected-state mutation when safe."""
    result = {'school_id': target['id'], 'state': str(target.get('state') or '').strip(), 'reason': None}

    def reject(reason):
        result['reason'] = reason
        return result, None

    if target.get('classification') != 'public':
        return reject('private_or_independent')
    if target.get('canonical_id') is not None:
        return reject('legacy_alias')
    if target.get('source') != 'nces-public':
        return reject('unverified_school_source')
    try:
        ncessch = normalize_id(target.get('source_id'), 12)
    except ValueError:
        return reject('invalid_nces_school_id')
    school = schools.get(ncessch)
    if school is None:
        return reject('school_missing_from_official_source')
    try:
        target_year = normalize_year(target.get('source_year'))
    except ValueError:
        return reject('invalid_target_source_year')
    if target_year != school['source_year']:
        return reject('school_source_year_mismatch')
    if target.get('source_dataset') != school['source_dataset']:
        return reject('school_source_dataset_mismatch')
    if str(target.get('state') or '').strip() != school['state']:
        return reject('school_physical_state_mismatch')
    district = districts.get(school['leaid'])
    if district is None:
        return reject('district_missing_from_official_source')
    if district['source_year'] != school['source_year']:
        return reject('district_source_year_mismatch')
    # STATE is a physical office/campus location, not always jurisdiction.
    # Explicit operating FIPS must agree; verified cross-state campuses remain
    # linked to their actual LEA rather than to a nearby district.
    if school['opstfips'] != district['metadata']['opstfips']:
        return reject('operating_jurisdiction_mismatch')
    desired_id = 'nces-lea:' + district['leaid']
    result.update(district_id=desired_id, district_name=district['name'],
                  district_state=district['state'], cross_state=school['state'] != district['state'])
    current_id = target.get('district_id')
    current_text = str(target.get('district') or '').strip()
    if current_id:
        try:
            current_year = normalize_year(target.get('district_source_year'))
        except ValueError:
            return reject('existing_relationship_requires_review')
        if current_id == desired_id and current_year == school['source_year']:
            return reject('already_linked')
        return reject('existing_relationship_requires_review')
    if current_text and current_text != district['name']:
        return reject('existing_district_text_requires_review')
    relationship = dict(ncessch=ncessch, leaid=district['leaid'], name=district['name'],
                        school_state=school['state'], district_state=district['state'],
                        school_opstfips=school['opstfips'], district_opstfips=district['metadata']['opstfips'],
                        source_year=school['source_year'], school_source_dataset=school['source_dataset'],
                        district_source_dataset=district['source_dataset'], source_url=district['source_url'],
                        school_source_url=school['source_url'])
    result['reason'] = 'link'
    return result, dict(school_id=target['id'], expected={field: target.get(field) for field in EXPECTED_FIELDS},
                        relationship=relationship)


def build_plan(targets, schools, districts, manifest, url):
    project_id, origin = project_identity(url)
    reasons, states, changes, assessments = collections.Counter(), {}, [], []
    seen = set()
    for target in sorted(targets, key=lambda row: row['id']):
        if target['id'] in seen:
            raise ValueError('Duplicate target school ID')
        seen.add(target['id'])
        assessment, change = assess_school(target, schools, districts)
        reasons[assessment['reason']] += 1
        states.setdefault(assessment['state'] or 'UNKNOWN', collections.Counter())[assessment['reason']] += 1
        assessments.append(assessment)
        if change:
            changes.append(change)
    return dict(format=FORMAT, created_at=dt.datetime.now(dt.timezone.utc).isoformat(),
                project_id=project_id, supabase_url=origin, source_manifest=manifest,
                coverage=dict(target_schools=len(targets), official_schools=len(schools), official_districts=len(districts),
                              changes=len(changes), by_reason=dict(reasons),
                              by_state={state: dict(counts) for state, counts in sorted(states.items())},
                              verified_cross_physical_state=sum(bool(row.get('cross_state')) for row in assessments)),
                assessments=assessments, changes=changes)


def write_plan(plan, path):
    path = Path(path)
    data = (json.dumps(plan, ensure_ascii=True, sort_keys=True, indent=2) + '\n').encode()
    digest = hashlib.sha256(data).hexdigest()
    path.parent.mkdir(parents=True, exist_ok=True)
    if path.exists() or Path(str(path) + '.sha256').exists():
        raise ValueError('Plan/sidecar already exists; use a fresh output path for a new review')
    with path.open('xb') as handle:
        handle.write(data)
    with Path(str(path) + '.sha256').open('x', encoding='ascii') as handle:
        handle.write(digest + '\n')
    return digest


def _checkpoint(path, value):
    # A crashed process may leave its temporary file. Use a unique sibling so a
    # subsequent acknowledged retry can still replace the checkpoint atomically.
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(mode='w',encoding='utf-8',dir=path.parent,
                                         prefix=path.name+'.',suffix='.tmp',delete=False) as handle:
            temporary = Path(handle.name)
            json.dump(value, handle, sort_keys=True)
            handle.write('\n')
            handle.flush()
            os.fsync(handle.fileno())
        temporary.replace(path)
    finally:
        if temporary is not None and temporary.exists():
            temporary.unlink()


def apply_plan(path, url, service_key, confirm_project, reviewed_by, reviewed_sha256,
               batch_size=100, requester=request, checkpoint_path=None):
    project_id, origin = project_identity(url)
    if confirm_project != project_id:
        raise ValueError('Explicit project confirmation must exactly match the target project ID')
    if not service_key or not reviewed_by or len(reviewed_by.strip()) < 3:
        raise ValueError('A server-only key and named reviewer are required')
    if not 1 <= batch_size <= 500:
        raise ValueError('Batch size must be 1..500')
    path = Path(path)
    raw = path.read_bytes()
    digest = hashlib.sha256(raw).hexdigest()
    if not reviewed_sha256 or digest != reviewed_sha256.strip() or Path(str(path) + '.sha256').read_text().strip() != digest:
        raise ValueError('Reviewed plan checksum does not match its immutable file/sidecar')
    plan = json.loads(raw)
    if plan.get('format') != FORMAT or plan.get('project_id') != project_id or plan.get('supabase_url') != origin:
        raise ValueError('Plan format or project identity mismatch')
    changes = plan.get('changes')
    if not isinstance(changes, list) or len(changes) != plan.get('coverage', {}).get('changes'):
        raise ValueError('Plan has an invalid change inventory')
    for row in changes:
        if not row.get('school_id') or not isinstance(row.get('expected'), dict) or set(row['expected']) != set(EXPECTED_FIELDS) or not isinstance(row.get('relationship'), dict):
            raise ValueError('Invalid/stale-state-free plan entry; regenerate the preview')
    checkpoint_path = Path(checkpoint_path or str(path) + '.checkpoint.json')
    checkpoint = dict(project_id=project_id, plan_sha256=digest, next_index=0, total=len(changes))
    if checkpoint_path.exists():
        prior = json.loads(checkpoint_path.read_text())
        if prior.get('project_id') != project_id or prior.get('plan_sha256') != digest or prior.get('total') != len(changes) or not isinstance(prior.get('next_index'), int) or not 0 <= prior['next_index'] <= len(changes):
            raise ValueError('Checkpoint belongs to a different plan or has an invalid position')
        checkpoint = prior
    applied, unchanged = 0, 0
    for offset in range(checkpoint['next_index'], len(changes), batch_size):
        batch = changes[offset:offset + batch_size]
        result = requester(origin + '/rest/v1/rpc/apply_school_district_batch',
                           {'p_rows': batch, 'p_reviewed_by': reviewed_by.strip(), 'p_plan_sha256': digest},
                           _headers(service_key))
        if not isinstance(result, dict) or not all(isinstance(result.get(key), int) and result[key] >= 0 for key in ('applied', 'unchanged')) or result['applied'] + result['unchanged'] != len(batch):
            raise ValueError('Unexpected batch acknowledgement; checkpoint was not advanced')
        applied += result['applied']
        unchanged += result['unchanged']
        checkpoint['next_index'] = offset + len(batch)
        _checkpoint(checkpoint_path, checkpoint)
    return dict(complete=True, project_id=project_id, plan_sha256=digest,
                acknowledged=len(changes), applied_this_run=applied, unchanged_this_run=unchanged)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--preview', action='store_true', help='Read-only (default)')
    parser.add_argument('--output', default='private/school-district-plan.json')
    parser.add_argument('--year', default=DEFAULT_YEAR)
    parser.add_argument('--cache-dir', default='private/nces-district-cache')
    parser.add_argument('--school-csv')
    parser.add_argument('--district-csv')
    parser.add_argument('--client-config', help='Public Flutter JSON config; no secrets')
    parser.add_argument('--apply-plan')
    parser.add_argument('--confirm-project')
    parser.add_argument('--reviewed-by')
    parser.add_argument('--reviewed-sha256')
    parser.add_argument('--checkpoint')
    parser.add_argument('--batch-size', type=int, default=100)
    args = parser.parse_args(argv)
    config = json.loads(Path(args.client_config).read_text()) if args.client_config else {}
    url = os.getenv('SUPABASE_URL') or config.get('SUPABASE_URL')
    if not url:
        parser.error('Set SUPABASE_URL or a public --client-config')
    if args.apply_plan:
        if args.preview:
            parser.error('--preview and --apply-plan are mutually exclusive')
        result = apply_plan(args.apply_plan, url, os.getenv('SUPABASE_SERVICE_ROLE_KEY'),
                            args.confirm_project, args.reviewed_by, args.reviewed_sha256,
                            args.batch_size, checkpoint_path=args.checkpoint)
        print(json.dumps(result, sort_keys=True))
        return 0
    public_key = os.getenv('SUPABASE_PUBLISHABLE_KEY') or config.get('SUPABASE_PUBLISHABLE_KEY')
    if not public_key:
        parser.error('A public SUPABASE_PUBLISHABLE_KEY is required for read-only preview')
    schools, districts, manifest = load_catalog(args.year, args.cache_dir, args.school_csv, args.district_csv)
    targets = fetch_target_schools(url, public_key)
    plan = build_plan(targets, schools, districts, manifest, url)
    digest = write_plan(plan, args.output)
    print(json.dumps(dict(preview_only=True, production_writes=False, project_id=plan['project_id'],
                         plan=args.output, reviewed_sha256=digest, coverage=plan['coverage']), sort_keys=True))
    return 0


if __name__ == '__main__':
    try:
        sys.exit(main())
    except (ValueError, OSError, urllib.error.URLError) as error:
        # No credential values or request headers are printed.
        print('District workflow stopped: ' + str(error), file=sys.stderr)
        sys.exit(1)

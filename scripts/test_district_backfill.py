import copy
import hashlib
import io
import json
from pathlib import Path
import tempfile
import unittest
import urllib.error
import urllib.parse

from backfill_school_districts import (EXPECTED_FIELDS, apply_plan, assess_school, build_plan,
                                       fetch_target_schools, project_identity, write_plan)
from nces_districts import (_official_rows, district_payload, load_catalog, normalize_district,
                            normalize_id, normalize_school, normalize_year, year_code)

PROJECT = 'abcdefghijklmnopqrst'
URL = f'https://{PROJECT}.supabase.co'


def school_row(identifier='010000500870', lea='0100005', state='AL', operating='01'):
    return dict(NCESSCH=identifier, LEAID=lea, STATE=state, OPSTFIPS=operating, SCHOOLYEAR='2024-2025')


def district_row(lea='0100005', name='Official District', state='AL', operating='01'):
    return dict(LEAID=lea, NAME=name, STATE=state, OPSTFIPS=operating, SCHOOLYEAR='2024-2025')


def target(identifier='010000500870'):
    return dict(id=identifier, classification='public', canonical_id=None, source='nces-public',
                source_id=identifier, source_dataset='EDGE_GEOCODE_PUBLICSCH_2425',
                source_year='2024-2025', state='AL', district=None,
                district_id=None, district_source_year=None)


def catalog():
    school = normalize_school(school_row())
    district = normalize_district(district_row())
    return {school['ncessch']: school}, {district['leaid']: district}


class SourceTests(unittest.TestCase):
    def test_exact_ids_and_consecutive_years(self):
        self.assertEqual(normalize_id('0100005', 7), '0100005')
        self.assertEqual(normalize_id(100005, 7), '0100005')
        self.assertEqual(normalize_year('2425'), '2024-2025')
        self.assertEqual(normalize_year('2024–2025'), '2024-2025')
        self.assertEqual(year_code('2024-2025'), '2425')
        for value in ['2024', '2024-2026', '', None]:
            with self.assertRaises(ValueError):
                normalize_year(value)
        for value in ['100005', '1e5', None, -1, True, '0000000']:
            with self.assertRaises(ValueError):
                normalize_id(value, 7)

    def test_explicit_lea_relationship_is_not_overridden_by_ncessch_prefix(self):
        row = school_row(lea='0199999')
        self.assertEqual(normalize_school(row)['leaid'], '0199999')

    def test_official_names_distinct_ids_and_operating_jurisdiction(self):
        left = normalize_district(district_row(name='Shared Name'))
        right = normalize_district(district_row(lea='0200005', name='Shared Name', state='AK', operating='02'))
        self.assertNotEqual(district_payload(left)['id'], district_payload(right)['id'])
        self.assertEqual(district_payload(left)['metadata']['opstfips'], '01')

    def test_duplicate_source_rows_fail_closed_and_csv_checksums_are_recorded(self):
        import csv
        with tempfile.TemporaryDirectory() as directory:
            school_path, district_path = Path(directory) / 'schools.csv', Path(directory) / 'districts.csv'
            for path, rows in [(school_path, [school_row()]), (district_path, [district_row()])]:
                with path.open('w', newline='') as handle:
                    writer = csv.DictWriter(handle, fieldnames=list(rows[0]))
                    writer.writeheader(); writer.writerows(rows)
            schools, districts, manifest = load_catalog(school_csv=school_path, district_csv=district_path)
            self.assertEqual(len(schools), 1); self.assertEqual(len(districts), 1)
            self.assertEqual(manifest['schools']['sha256'], hashlib.sha256(school_path.read_bytes()).hexdigest())
            with school_path.open('a', newline='') as handle:
                csv.DictWriter(handle, fieldnames=list(school_row())).writerow(school_row())
            with self.assertRaisesRegex(ValueError, 'Duplicate'):
                load_catalog(school_csv=school_path, district_csv=district_path)

    def test_official_pagination_rejects_missing_records(self):
        fields = [dict(name=name, type='esriFieldTypeString') for name in school_row()]
        fields.append(dict(name='OBJECTID', type='esriFieldTypeOID'))

        def requester(url):
            if '/query' not in url:
                return {'fields': fields}
            if 'returnIdsOnly' in url:
                return {'objectIds': [1, 2]}
            return {'features': [{'attributes': dict(OBJECTID=1, **school_row())}]}
        with self.assertRaisesRegex(ValueError, 'Incomplete'):
            _official_rows('schools', '2425', requester)


class PreviewTests(unittest.TestCase):
    def test_exact_school_join_and_stale_state_expectations(self):
        schools, districts = catalog()
        assessment, change = assess_school(target(), schools, districts)
        self.assertEqual(assessment['reason'], 'link')
        self.assertEqual(change['relationship']['leaid'], '0100005')
        self.assertEqual(set(change['expected']), set(EXPECTED_FIELDS))
        self.assertIsNone(change['expected']['district_id'])
        self.assertEqual(change['relationship']['school_opstfips'], '01')

    def test_missing_private_alias_year_state_and_unverified_sources_are_not_linked(self):
        schools, districts = catalog()
        cases = [({'classification': 'private'}, 'private_or_independent'),
                 ({'canonical_id': 'canonical'}, 'legacy_alias'),
                 ({'source': None}, 'unverified_school_source'),
                 ({'source_id': 'bad'}, 'invalid_nces_school_id'),
                 ({'source_id': '019999999999'}, 'school_missing_from_official_source'),
                 ({'source_year': '2023-2024'}, 'school_source_year_mismatch'),
                 ({'source_year': None}, 'invalid_target_source_year'),
                 ({'source_dataset': 'different'}, 'school_source_dataset_mismatch'),
                 ({'state': 'AK'}, 'school_physical_state_mismatch')]
        for override, reason in cases:
            with self.subTest(reason=reason):
                assessment, change = assess_school(dict(target(), **override), schools, districts)
                self.assertEqual(assessment['reason'], reason); self.assertIsNone(change)
        self.assertEqual(assess_school(target(), schools, {})[0]['reason'], 'district_missing_from_official_source')

    def test_catalog_year_and_operating_fips_mismatch_are_blocked(self):
        schools, districts = catalog()
        district = districts['0100005']
        district['source_year'] = '2023-2024'
        self.assertEqual(assess_school(target(), schools, districts)[0]['reason'], 'district_source_year_mismatch')
        district['source_year'] = '2024-2025'; district['metadata']['opstfips'] = '02'
        self.assertEqual(assess_school(target(), schools, districts)[0]['reason'], 'operating_jurisdiction_mismatch')

    def test_real_cross_physical_state_relationship_is_retained(self):
        schools, districts = catalog()
        districts['0100005']['state'] = 'MD'
        assessment, change = assess_school(target(), schools, districts)
        self.assertEqual(assessment['reason'], 'link'); self.assertTrue(assessment['cross_state'])
        self.assertEqual(change['relationship']['school_state'], 'AL')
        self.assertEqual(change['relationship']['district_state'], 'MD')

    def test_existing_relationship_and_legacy_text_conflicts_are_review_only(self):
        schools, districts = catalog()
        linked = dict(target(), district_id='nces-lea:0100005', district_source_year='2024-2025')
        self.assertEqual(assess_school(linked, schools, districts)[0]['reason'], 'already_linked')
        linked['district_id'] = 'nces-lea:0299999'
        self.assertEqual(assess_school(linked, schools, districts)[0]['reason'], 'existing_relationship_requires_review')
        assessment, change = assess_school(dict(target(), district='Manual district value'), schools, districts)
        self.assertEqual(assessment['reason'], 'existing_district_text_requires_review'); self.assertIsNone(change)

    def test_coverage_has_state_and_disposition_counts(self):
        schools, districts = catalog()
        targets = [target(), dict(target('nces-private:12345678'), classification='private', source='nces-private')]
        plan = build_plan(targets, schools, districts, {}, URL)
        self.assertEqual(plan['coverage']['changes'], 1)
        self.assertEqual(plan['coverage']['by_state']['AL']['link'], 1)
        self.assertEqual(plan['coverage']['by_reason']['private_or_independent'], 1)
        with self.assertRaises(ValueError):
            build_plan([target(), target()], schools, districts, {}, URL)

    def test_rest_keyset_pagination_and_genuine_pre_migration_fallback(self):
        calls = []
        rows = [target('010000500870'), target('010000500871'), target('010000500879')]

        def requester(url, payload=None, headers=None):
            calls.append(url)
            query = urllib.parse.parse_qs(urllib.parse.urlparse(url).query)
            if query['select'] == ['district_id']:
                raise urllib.error.HTTPError(url, 400, 'Bad Request', {}, io.BytesIO(json.dumps(
                    {'code': '42703', 'message': 'column schools.district_id does not exist'}).encode()))
            self.assertNotIn('district_id', query['select'][0])
            return rows[:2] if 'id' not in query else rows[2:]
        self.assertEqual(len(fetch_target_schools(URL, 'public-key', requester, 2)), 3)
        self.assertIn('gt.010000500871', urllib.parse.unquote(calls[-1]))

        def unauthorized(url, payload=None, headers=None):
            raise urllib.error.HTTPError(url, 401, 'Unauthorized', {}, io.BytesIO(b'{}'))
        with self.assertRaises(urllib.error.HTTPError):
            fetch_target_schools(URL, 'public-key', unauthorized)


class ApplyTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.path = Path(self.temporary.name) / 'plan.json'
        schools, districts = catalog()
        self.plan = build_plan([target()], schools, districts, {}, URL)
        self.digest = write_plan(self.plan, self.path)

    def test_plan_is_immutable_and_apply_needs_reviewed_identity(self):
        with self.assertRaisesRegex(ValueError, 'already exists'):
            write_plan(self.plan, self.path)
        calls = []
        requester = lambda *args, **kwargs: calls.append(args)
        for confirmation, reviewer, checksum, key in [('wrong', 'reviewer', self.digest, 'server-key'),
                                                     (PROJECT, '', self.digest, 'server-key'),
                                                     (PROJECT, 'reviewer', '0' * 64, 'server-key'),
                                                     (PROJECT, 'reviewer', self.digest, None)]:
            with self.assertRaises(ValueError):
                apply_plan(self.path, URL, key, confirmation, reviewer, checksum, requester=requester)
        self.assertEqual(calls, [])
        with self.assertRaises(ValueError):
            project_identity('https://wrong.example')

    def test_success_checkpoint_and_repeat_are_no_op(self):
        calls = []

        def requester(url, payload, headers):
            calls.append(payload)
            self.assertEqual(payload['p_plan_sha256'], self.digest)
            self.assertEqual(payload['p_rows'][0]['expected'], self.plan['changes'][0]['expected'])
            return {'applied': 1, 'unchanged': 0}
        result = apply_plan(self.path, URL, 'server-key', PROJECT, 'reviewer', self.digest, requester=requester)
        self.assertTrue(result['complete']); self.assertEqual(len(calls), 1)
        apply_plan(self.path, URL, 'server-key', PROJECT, 'reviewer', self.digest, requester=requester)
        self.assertEqual(len(calls), 1)

    def test_failed_batch_does_not_advance_checkpoint_and_can_retry_idempotently(self):
        checkpoint = Path(str(self.path) + '.checkpoint.json')

        def failure(*args, **kwargs):
            raise ValueError('Stale expected school state')
        with self.assertRaisesRegex(ValueError, 'Stale'):
            apply_plan(self.path, URL, 'server-key', PROJECT, 'reviewer', self.digest, requester=failure)
        self.assertFalse(checkpoint.exists())
        result = apply_plan(self.path, URL, 'server-key', PROJECT, 'reviewer', self.digest,
                            requester=lambda *args, **kwargs: {'applied': 0, 'unchanged': 1})
        self.assertEqual(result['unchanged_this_run'], 1)

    def test_abandoned_temporary_checkpoint_does_not_block_resume(self):
        abandoned=Path(str(self.path)+'.checkpoint.json.tmp')
        abandoned.write_text('interrupted older process')
        result=apply_plan(self.path,URL,'server-key',PROJECT,'reviewer',self.digest,
                          requester=lambda *args,**kwargs:{'applied':1,'unchanged':0})
        self.assertTrue(result['complete'])
        self.assertTrue(Path(str(self.path)+'.checkpoint.json').exists())
        self.assertEqual(abandoned.read_text(),'interrupted older process')

    def test_bad_acknowledgement_or_modified_review_file_stops(self):
        with self.assertRaisesRegex(ValueError, 'acknowledgement'):
            apply_plan(self.path, URL, 'server-key', PROJECT, 'reviewer', self.digest,
                       requester=lambda *args, **kwargs: {'applied': 0, 'unchanged': 0})
        self.assertFalse(Path(str(self.path) + '.checkpoint.json').exists())
        self.path.write_text(self.path.read_text() + '\n')
        with self.assertRaisesRegex(ValueError, 'checksum'):
            apply_plan(self.path, URL, 'server-key', PROJECT, 'reviewer', self.digest)


if __name__ == '__main__':
    unittest.main()

import datetime as dt
import hashlib
import json
from pathlib import Path
import tempfile
import unittest
import contextlib
import io
from unittest.mock import patch
from infrastructure_coverage import coverage_record, coverage_sql, CATEGORIES
from import_infrastructure import main as import_main


class CoverageTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.file = Path(self.temp.name) / 'features.geojsonseq'
        self.file.write_text('', encoding='utf-8')
        self.manifest = Path(str(self.file) + '.manifest.json')
        self.timestamp = (dt.datetime.now(dt.timezone.utc)-dt.timedelta(days=1)).isoformat()
        self.data = dict(version=1, complete=True, bounds=[-88.25,41.96,-87.94,42.13],
            source_url='https://download.geofabrik.de/north-america/us/illinois-latest.osm.pbf',
            source_updated_at=self.timestamp,categories=sorted(CATEGORIES),file_sha256=hashlib.sha256(b'').hexdigest())

    def record(self):
        self.manifest.write_text(json.dumps(self.data),encoding='utf-8')
        return coverage_record(self.file,self.manifest,"Schaumburg's test",self.timestamp,0)

    def test_complete_empty_export_can_be_registered_after_review(self):
        record=self.record()
        self.assertEqual(record['feature_count'],0)
        sql=coverage_sql(record)
        self.assertIn('on conflict(id) do update',sql)
        self.assertIn("Schaumburg''s test",sql)
        self.assertNotIn('delete ',sql.lower())

    def test_modified_export_rejected(self):
        self.file.write_text('changed',encoding='utf-8')
        with self.assertRaisesRegex(ValueError,'checksum'): self.record()

    def test_incomplete_unbounded_untrusted_and_wrong_year_rejected(self):
        for key,value in [('complete',False),('bounds',[-180,-85,180,85]),
                          ('source_url','https://untrusted.test/extract'),
                          ('source_updated_at','2020-01-01T00:00:00Z'),('categories',['sidewalk'])]:
            with self.subTest(key=key):
                old=self.data[key]; self.data[key]=value
                with self.assertRaises(ValueError): self.record()
                self.data[key]=old

    def test_stale_sql_bundles_and_conflicting_dry_run_are_rejected(self):
        directory=Path(self.temp.name)/'sql'
        directory.mkdir()
        (directory/'00001.sql').write_text('old batch',encoding='utf-8')
        base=['import_infrastructure.py',str(self.file),'--region','test','--source-updated-at',self.timestamp,'--sql-dir',str(directory)]
        for args in [base,base+['--dry-run']]:
            with patch('sys.argv',args),contextlib.redirect_stderr(io.StringIO()):
                with self.assertRaises(SystemExit) as error: import_main()
                self.assertEqual(error.exception.code,2)
        self.assertEqual((directory/'00001.sql').read_text(encoding='utf-8'),'old batch')

    def test_skipped_geometry_cannot_publish_complete_coverage(self):
        self.file.write_text(json.dumps({'properties':{'@id':'n1','highway':'crossing'},
            'geometry':{'type':'Point','coordinates':[190,42]}})+'\n',encoding='utf-8')
        self.data['file_sha256']=hashlib.sha256(self.file.read_bytes()).hexdigest()
        self.manifest.write_text(json.dumps(self.data),encoding='utf-8')
        directory=Path(self.temp.name)/'sql'
        args=['import_infrastructure.py',str(self.file),'--region','test','--source-updated-at',
            self.timestamp,'--coverage-manifest',str(self.manifest),'--sql-dir',str(directory)]
        with patch('sys.argv',args),contextlib.redirect_stderr(io.StringIO()):
            self.assertEqual(import_main(),1)
        self.assertFalse((directory/'coverage-after-review.sql').exists())


if __name__=='__main__': unittest.main()

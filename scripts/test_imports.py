import unittest
from import_schools import normalize, sql_batch
from import_infrastructure import classify, valid_geometry, CrossingIndex


class ImportTests(unittest.TestCase):
    def row(self, **extra):
        return dict(NAME="O'Brien School", NCESSCH='001234567890', PPIN='00123456', LAT=42, LON=-88, SCHOOLYEAR='2024-2025', **extra)

    def test_separate_schemas_and_leading_zeros(self):
        public = normalize(self.row(), 'public', '2425', set())
        private = normalize(self.row(), 'private', '2324', set())
        self.assertEqual(public['id'], '001234567890')
        self.assertEqual(private['id'], 'nces-private:00123456')
        self.assertNotEqual(public['source'], private['source'])

    def test_duplicate_ids_rejected_but_colocated_distinct_schools_preserved(self):
        seen = set()
        normalize(self.row(), 'public', '2425', seen)
        with self.assertRaises(ValueError):
            normalize(self.row(), 'public', '2425', seen)
        other = self.row(); other['NCESSCH'] = '001234567891'
        self.assertEqual(normalize(other, 'public', '2425', seen)['latitude'],42)

    def test_invalid_required_values(self):
        for key,value in [('LAT',float('nan')),('LON',181),('NAME',''),('NCESSCH','')]:
            row = self.row(); row[key] = value
            with self.assertRaises(ValueError):
                normalize(row,'public','2425',set())

    def test_sql_literals_escape_apostrophes_and_upsert_stable_id(self):
        sql = sql_batch([normalize(self.row(),'public','2425',set())])
        self.assertIn("O''Brien",sql)
        self.assertIn('on conflict(id) do update',sql)

    def test_footway_is_not_automatically_a_sidewalk(self):
        self.assertEqual(classify({'highway':'footway'}),['walkingPath'])
        self.assertEqual(classify({'highway':'footway','footway':'sidewalk'}),['sidewalk'])
        self.assertEqual(classify({'highway':'footway','footway':'crossing'}),['crossing'])
        self.assertEqual(classify({'highway':'residential','sidewalk':'no'}),[])

    def test_directional_bicycle_tags_and_access(self):
        self.assertIn('bikeLane',classify({'highway':'residential','cycleway:left':'lane'}))
        self.assertIn('bikePath',classify({'highway':'residential','cycleway:right':'track'}))
        self.assertNotIn('bikePath',classify({'highway':'cycleway','bicycle':'no'}))
        self.assertEqual(classify({'highway':'footway','access':'private'}),[])

    def test_geometry_validation(self):
        self.assertTrue(valid_geometry({'type':'LineString','coordinates':[[-88,42],[-88.1,42.1]]}))
        self.assertFalse(valid_geometry({'type':'Point','coordinates':[190,42]}))
        self.assertFalse(valid_geometry({'type':'Point','coordinates':[]}))

    def test_crossing_deduplication_keeps_way_only_crossings(self):
        index = CrossingIndex()
        way = {'type':'LineString','coordinates':[[-88,42],[-88,42.0001]]}
        self.assertFalse(index.touches(way))
        index.add([-88,42])
        self.assertTrue(index.touches(way))


if __name__ == '__main__':
    unittest.main()

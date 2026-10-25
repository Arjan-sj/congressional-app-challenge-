"""Stream only supported infrastructure from a regional PBF to GeoJSON lines.

Optional dependency: osmium (see requirements-infrastructure.txt). Full OSM nodes
are used only in this backend process to resolve way geometry, never in Flutter.
"""
import argparse
import json
import hashlib
import math
from pathlib import Path
from import_infrastructure import classify, CrossingIndex


def main():
    import osmium
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('pbf')
    p.add_argument('output')
    p.add_argument('--bbox', help='Optional west,south,east,north test region')
    p.add_argument('--source-url', help='Official licensed regional extract URL, recorded in manifest')
    args = p.parse_args()
    bounds = list(map(float, args.bbox.split(','))) if args.bbox else None
    if bounds and (len(bounds) != 4 or not all(math.isfinite(v) for v in bounds)
                   or not -180 <= bounds[0] < bounds[2] <= 180
                   or not -85 <= bounds[1] < bounds[3] <= 85):
        p.error('bbox must be west,south,east,north')
    with osmium.io.Reader(args.pbf) as reader:
        timestamp = reader.header().get('osmosis_replication_timestamp')
        print(json.dumps({'replication_timestamp': timestamp}))

    class Infrastructure(osmium.SimpleHandler):
        count = 0
        incomplete_ways = 0
        crossings = CrossingIndex()
        def emit(self, identifier, tags, geometry):
            if bounds:
                points = [geometry['coordinates']] if geometry['type'] == 'Point' else geometry['coordinates']
                if max(p[0] for p in points) < bounds[0] or min(p[0] for p in points) > bounds[2] or max(p[1] for p in points) < bounds[1] or min(p[1] for p in points) > bounds[3]:
                    return
            output.write(json.dumps({'type': 'Feature', 'properties': {'@id': identifier, **tags}, 'geometry': geometry}, separators=(',', ':')) + '\n')
            self.count += 1
        def node(self, node):
            if node.tags.get('highway') == 'crossing' and node.location.valid():
                self.crossings.add([node.location.lon, node.location.lat])
                self.emit('n' + str(node.id), dict(node.tags), {'type': 'Point', 'coordinates': [node.location.lon, node.location.lat]})
        def way(self, way):
            tags = dict(way.tags)
            if not classify(tags):
                return
            coordinates = [[node.lon, node.lat] for node in way.nodes if node.location.valid()]
            if len(coordinates) != len(way.nodes) or len(coordinates) < 2:
                self.incomplete_ways += 1
                return
            geometry = {'type': 'LineString', 'coordinates': coordinates}
            if tags.get('footway') == 'crossing' and self.crossings.touches(geometry):
                return
            self.emit('w' + str(way.id), tags, geometry)

    with Path(args.output).open('w', encoding='utf-8') as output:
        handler = Infrastructure()
        handler.apply_file(args.pbf, locations=True, idx='flex_mem')
    if bounds and args.source_url and timestamp:
        with Path(args.output).open('rb') as exported:
            checksum = hashlib.file_digest(exported, 'sha256').hexdigest()
        manifest = dict(version=1, bounds=bounds, source_url=args.source_url,
                        source_updated_at=timestamp, file_sha256=checksum,
                        categories=['sidewalk','walkingPath','crossing','bikePath','bikeLane'],
                        complete=handler.incomplete_ways == 0, exported=handler.count)
        Path(args.output + '.manifest.json').write_text(json.dumps(manifest, indent=2), encoding='utf-8')
    print(json.dumps({'exported': handler.count, 'incomplete_ways': handler.incomplete_ways}))


if __name__ == '__main__':
    main()

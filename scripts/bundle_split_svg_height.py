"""Bundle runtime fields only; retain source evidence in the audit directory."""
import argparse
import gzip
import hashlib
import json
from pathlib import Path


def fields(row, names):
    return {name: row[name] for name in names if name in row}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--input', type=Path, required=True)
    parser.add_argument('--output', type=Path, default=Path('assets/maps'))
    parser.add_argument('--report', type=Path, required=True)
    args = parser.parse_args()
    report = []
    for side in ('attack', 'defense'):
        source = args.input / f'split-{side}.json'
        source_bytes = source.read_bytes()
        model = json.loads(source_bytes)
        assert model['version'] == 2 and model['side'] == side
        if any(w['unknownHeight'] or any(high is None for _, high in w['bands'])
               for w in model['walls']):
            raise ValueError('Assumed or unknown wall heights cannot be bundled')
        packed = fields(model, ('version', 'map', 'side', 'coordinateSpace',
                               'verticalSpace', 'viewBox',
                               'defaultCameraHeightMeters', 'ground'))
        packed['sourceSvg'] = fields(model['sourceSvg'], ('sha256',))
        packed['walls'] = [fields(row, ('id', 'rings', 'fillRule', 'bands',
                                        'unknownHeight', 'floorElevationMeters'))
                           for row in model['walls']]
        packed['supports'] = [fields(row, ('id', 'label', 'rings', 'fillRule',
                             'heightAboveFloorMeters', 'floorElevationMeters',
                             'surfaceElevationMeters', 'surfacePlane',
                             'automaticStandingAllowed')) for row in model['supports']]
        packed['receiver'] = [fields(row, ('rings', 'fillRule'))
                              for row in model['receiver']]
        raw = json.dumps(packed, separators=(',', ':'), allow_nan=False).encode()
        compressed = gzip.compress(raw, compresslevel=9, mtime=0)
        output = args.output / f'split_svg_height_{side}.json.gz'
        output.write_bytes(compressed)
        assert json.loads(gzip.decompress(output.read_bytes())) == packed
        report.append(dict(side=side, source=str(source), output=str(output),
                           sourceSha256=hashlib.sha256(source_bytes).hexdigest(),
                           bundledSha256=hashlib.sha256(compressed).hexdigest(),
                           sourceBytes=len(source_bytes), rawBytes=len(raw),
                           bundledBytes=len(compressed),
                           walls=len(packed['walls']), supports=len(packed['supports'])))
    args.report.write_text(json.dumps(report, indent=2))
    print(json.dumps(report))


if __name__ == '__main__':
    main()

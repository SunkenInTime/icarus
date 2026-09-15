"""Remove audit metadata from a reviewed model without rounding geometry."""
import argparse
import gzip
import hashlib
import json
from pathlib import Path


def compile_model(model):
    result = {key: model[key] for key in (
        'version', 'coordinateSpace', 'verticalSpace',
        'defaultCameraHeightMeters', 'cellSizeSvg') if key in model}
    result['walls'] = [{key: wall[key] for key in (
        'id', 'rings', 'fillRule', 'bands', 'unknownHeight')}
        for wall in model['walls']]
    result['supports'] = [{key: support[key] for key in (
        'id', 'rings', 'fillRule', 'heightAboveFloorMeters')}
        for support in model['supports']]
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--input', type=Path, required=True)
    parser.add_argument('--out', type=Path, required=True)
    args = parser.parse_args()
    args.out.mkdir(exist_ok=False)
    reports = []
    for side in ('attack', 'defense'):
        source = args.input / f'split-{side}.json'
        original = source.read_bytes()
        model = compile_model(json.loads(original))
        encoded = json.dumps(model, separators=(',', ':'), allow_nan=False).encode()
        assert json.loads(encoded) == model
        (args.out / source.name).write_bytes(encoded)
        reports.append(dict(side=side, sourceSha256=hashlib.sha256(original).hexdigest(),
                            sourceBytes=len(original), runtimeBytes=len(encoded),
                            sourceGzipBytes=len(gzip.compress(original, mtime=0)),
                            runtimeGzipBytes=len(gzip.compress(encoded, mtime=0)),
                            coordinatesRounded=False))
    (args.out / 'review.json').write_text(json.dumps(reports, indent=2))
    print(json.dumps(reports, indent=2))


if __name__ == '__main__':
    main()

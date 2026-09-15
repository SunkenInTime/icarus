"""Prepare an isolated native candidate folder; query fixtures are supplied separately."""
import argparse
import gzip
import hashlib
import json
from pathlib import Path
import struct


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--pack', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    if args.output.exists():
        raise FileExistsError(args.output)
    compressed = args.pack.read_bytes()
    raw = gzip.decompress(compressed)
    magic, size = struct.unpack_from('<4sI', raw)
    if magic != b'IHD1': raise ValueError('Invalid height pack')
    header = json.loads(raw[8:8 + size])
    base = (8 + size + 7) // 8 * 8
    widths = {'float64': 8, 'uint32': 4, 'int32': 4}
    for item in header['arrays'].values():
        if item['offset'] < 0 or item['count'] < 0 or base + item['offset'] + item['count'] * widths[item['dtype']] > len(raw):
            raise ValueError('Invalid array bounds')
    args.output.mkdir(parents=True)
    (args.output / 'height-source.raw').write_bytes(raw)
    (args.output / 'header.json').write_text(json.dumps(header, indent=2))
    (args.output / 'arrays.txt').write_text('\n'.join(f'{name} {base + item["offset"]} {item["count"]}' for name, item in header['arrays'].items()))
    (args.output / 'parameters.txt').write_text(' '.join(format(x, '.17g') for x in header['heightDomainMeters']))
    (args.output / 'alpha-textures.txt').write_text('\n'.join(f'{i} {t["width"]} {t["height"]} {base + t["offset"]}' for i, t in enumerate(header['textures'])))
    wraps = {'repeat': 0, 'clamp': 1, 'mirror': 2, 'black': 3}
    (args.output / 'alpha-materials.txt').write_text('\n'.join(f'{m["material"]} {m["texture"]} {m["threshold"]:.17g} {m["alphaScale"]:.17g} {m["alphaBias"]:.17g} {wraps[m["wrapS"]]} {wraps[m["wrapT"]]}' for m in header['materials']))
    report = {'map': header['map'], 'packSha256': hashlib.sha256(compressed).hexdigest(),
              'rawSha256': hashlib.sha256(raw).hexdigest(), 'queryFixtures': 'Not included; callers must declare query provenance and side/floor transforms.'}
    (args.output / 'input-provenance.json').write_text(json.dumps(report, indent=2))
    print(json.dumps(report))


if __name__ == '__main__':
    main()

"""Stage one unchanged native pack with its display field and registered navigation."""
import argparse
import gzip
import hashlib
import json
from pathlib import Path
import struct


def digest(data):
    return hashlib.sha256(data).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--map', required=True)
    parser.add_argument('--source-directory', type=Path, required=True)
    parser.add_argument('--display-directory', type=Path, required=True)
    parser.add_argument('--navigation', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    name = args.map
    catalog = json.loads(Path('assets/maps/world/height_catalog.json').read_text())
    entry = catalog['maps'][name]
    files = {
        f'{name}.height.bin.gz': args.source_directory / f'{name}.height.bin.gz',
        f'{name}.tactical-ground.json.gz': args.source_directory / f'{name}.tactical-ground.json.gz',
        f'{name}.display-warp.json.gz': args.display_directory / f'{name}.display-warp.json.gz',
        f'{name}_navigation.json.gz': args.navigation,
    }
    data = {key: file.read_bytes() for key, file in files.items()}
    packed = data[f'{name}.height.bin.gz']
    raw = gzip.decompress(packed)
    magic, size = struct.unpack_from('<4sI', raw)
    if magic != b'IHD1':
        raise ValueError('Invalid native pack')
    header = json.loads(raw[8:8 + size])
    field = data[f'{name}.tactical-ground.json.gz']
    display = data[f'{name}.display-warp.json.gz']
    warp = json.loads(gzip.decompress(display))
    navigation = data[f'{name}_navigation.json.gz']
    if (header['map'] != name or warp['map'] != name or
            header['sourceGeometrySha256'] != entry['sourceGeometrySha256'] or
            warp['sourceGeometrySha256'] != entry['sourceGeometrySha256'] or
            header['policySha256'] != entry['policySha256'] or
            header['tacticalGroundFieldSha256'] != digest(field) or
            header.get('xyRegistration') is not None):
        raise ValueError('Source geometry, policy or unwarped ground binding mismatch')
    for side in ['attack', 'defense']:
        art = warp['art'][side]
        if digest(Path(art['file']).read_bytes()) != art['sha256']:
            raise ValueError('Display artwork changed')
    nav_proof_file = Path(str(args.navigation).replace('.json.gz', '.json.proof.json'))
    nav_proof = json.loads(nav_proof_file.read_text())
    if nav_proof['candidateNavigationSha256'] != digest(navigation):
        raise ValueError('Navigation proof does not identify staged bytes')
    entry.update(pack=f'{name}.height.bin.gz', packSha256=digest(packed), compressedBytes=len(packed),
                 rawSha256=digest(raw), rawBytes=len(raw), heightDomainMeters=header['heightDomainMeters'],
                 retainedFaces=header['retainedFaces'], navigation=f'{name}_navigation.json.gz',
                 navigationSha256=digest(navigation), navigationBytes=len(navigation),
                 tacticalGroundField={'file': f'{name}.tactical-ground.json.gz', 'sha256': digest(field), 'bytes': len(field)},
                 displayWarp={'file': f'{name}.display-warp.json.gz', 'sha256': digest(display), 'bytes': len(display)})
    entry.pop('upperChart', None)
    args.output.mkdir(parents=True, exist_ok=False)
    for filename, payload in data.items():
        (args.output / filename).write_bytes(payload)
    (args.output / 'height_catalog.json').write_text(json.dumps(catalog, indent=2))
    proof = {
        'map': name, 'format': 'icarus-display-only-staged-candidate-v1',
        'sourcePackCopiedBitwise': True, 'sourceGroundCopiedBitwise': True,
        'navigationProofSha256': digest(nav_proof_file.read_bytes()),
        'files': {key: {'source': str(files[key]), 'sha256': digest(value), 'bytes': len(value)} for key, value in data.items()},
        'catalogSha256': digest((args.output / 'height_catalog.json').read_bytes()),
        'nativeModelDirectory': str(args.source_directory / 'native'),
        'productionAssetsChanged': False, 'finalFloorSemanticsAccepted': False,
        'note': 'Only this map has local payloads. Other catalog entries remain unchanged. Candidate is for display integration and performance review; global ground policy remains provisional.'
    }
    (args.output / 'provenance.json').write_text(json.dumps(proof, indent=2))
    print(json.dumps({'map': name, 'directory': str(args.output), 'totalBytes': sum(map(len, data.values())), 'displayWarp': entry['displayWarp']}, indent=2))


if __name__ == '__main__':
    main()

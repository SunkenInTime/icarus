"""Stage verified candidate bytes with bound ground fields and a review catalog."""
import argparse
import copy
import gzip
import hashlib
import json
from pathlib import Path
import struct


def sha(data):
    return hashlib.sha256(data).hexdigest()


def seal(row, output, catalog_entry, suffix=''):
    name = row['map']
    source = Path(row['pack']).read_bytes()
    ground = Path(row['ground']).read_bytes()
    nav = Path(row['navigation']).read_bytes()
    for key, data in [('pack', source), ('ground', ground), ('navigation', nav)]:
        if row.get('sha256', {}).get(key, sha(data)) != sha(data):
            raise ValueError(f'{name} {key} changed since validation')
    source_raw = gzip.decompress(source)
    magic, size = struct.unpack_from('<4sI', source_raw)
    if magic != b'IHD1':
        raise ValueError('Invalid pack')
    header = json.loads(source_raw[8:8 + size])
    field = json.loads(gzip.decompress(ground))
    if header['map'] != name or field['map'] != name:
        raise ValueError('Mismatched map')
    expected_source_field = field.get('xyRegistration', {}).get('sourceFieldSha256', sha(ground))
    if header.get('tacticalGroundFieldSha256') != expected_source_field:
        raise ValueError(f'{name} geometry was baked against another ground field')
    proof = json.loads(Path(row['proof']).read_text())
    if proof['candidatePackSha256'] != sha(source):
        raise ValueError('Source composition proof does not identify these bytes')
    navigation_proof_sha = None
    if row.get('navigationProof'):
        navigation_proof_bytes = Path(row['navigationProof']).read_bytes()
        navigation_proof = json.loads(navigation_proof_bytes)
        if (navigation_proof['candidateNavigationSha256'] != sha(nav) or
                navigation_proof['sourceNavigationSha256'] != proof['sourceNavigationSha256']):
            raise ValueError('Navigation proof does not bind source and candidate')
        for key in ['unreachableInternalParents', 'missingOriginalPortalPairs', 'newUnauthorizedParentPairs']:
            if navigation_proof[key]:
                raise ValueError('Navigation connectivity proof failed')
        navigation_proof_sha = sha(navigation_proof_bytes)
    header['tacticalGroundFieldSha256'] = sha(ground)
    header['status'] = 'staged-tactical-candidate-not-gameplay-certified'
    header['xyRegistration'] = {
        'format': 'icarus-exact-local-xy-composition-v1',
        'unsealedPackSha256': sha(source),
        'compositionProofSha256': sha(Path(row['proof']).read_bytes()),
        'navigationSha256': sha(nav),
        'navigationProofSha256': navigation_proof_sha,
        'sourceGroundFieldSha256': expected_source_field,
        'composedGroundFieldSha256': sha(ground),
        'controlConstraints': proof['controlConstraints'],
    }
    payload = source_raw[(8 + size + 7) // 8 * 8:]
    encoded = json.dumps(header, separators=(',', ':'), allow_nan=False).encode()
    prefix = bytearray(struct.pack('<4sI', b'IHD1', len(encoded)) + encoded)
    prefix.extend(b'\0' * (-len(prefix) % 8))
    raw = prefix + payload
    packed = gzip.compress(raw, compresslevel=9, mtime=0)
    # All geometry, UV, material, alpha texture and BVH bytes remain identical.
    restored = gzip.decompress(packed)
    if restored[len(prefix):] != payload:
        raise ValueError('Header sealing changed the payload')
    pack_file = f'{name}{suffix}.height.bin.gz'
    ground_file = f'{name}{suffix}.tactical-ground.json.gz'
    for filename, data in [(pack_file, packed), (ground_file, ground)]:
        (output / filename).write_bytes(data)
    entry = copy.deepcopy(catalog_entry)
    entry.update(pack=pack_file, packSha256=sha(packed), compressedBytes=len(packed),
                 rawSha256=sha(raw), rawBytes=len(raw),
                 heightDomainMeters=header['heightDomainMeters'], retainedFaces=header['retainedFaces'],
                 tacticalGroundField={'file': ground_file, 'sha256': sha(ground), 'bytes': len(ground)})
    if not suffix:
        nav_file = f'{name}_navigation.json.gz'
        (output / nav_file).write_bytes(nav)
        entry.update(navigation=nav_file, navigationSha256=sha(nav), navigationBytes=len(nav))
    record = {'map': name, 'variant': suffix, 'source': row,
              'packSha256': sha(packed), 'rawSha256': sha(raw),
              'payloadSha256': sha(payload), 'payloadBytesUnchanged': True,
              'groundSha256': sha(ground), 'navigationSha256': sha(nav),
              'compressedBytes': len(packed), 'rawBytes': len(raw),
              'acceptedForGameplay': False}
    return entry, record


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--inventory', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--audit-root', type=Path, required=True)
    args = parser.parse_args()
    inventory = json.loads(args.inventory.read_text())
    catalog = json.loads(Path('assets/maps/world/height_catalog.json').read_text())
    if (len(inventory['maps']) != len(catalog['maps']) or
            {row['map'] for row in inventory['maps']} != set(catalog['maps'])):
        raise ValueError('Inventory must contain every catalog map exactly once')
    args.output.mkdir(parents=True, exist_ok=False)
    records = []
    for row in inventory['maps']:
        if row['status'] != 'artifact-ready' or row['runtimeChecks'] != 'passed':
            raise ValueError(f'{row["map"]} is not ready for staged sealing')
        name = row['map']
        entry, record = seal(row, args.output, catalog['maps'][name])
        catalog['maps'][name] = entry
        records.append(record)
        print(name, 'sealed', flush=True)
    # Keep the currently tested Fracture upper variant bound in this review
    # catalog. Its provisional floor selector remains explicitly uncertified.
    primary = next(row for row in inventory['maps'] if row['map'] == 'fracture')
    upper = {**primary, 'pack': str(args.audit_root / 'tactical-alignment-upper-v1/fracture/fracture.height.bin.gz'),
             'ground': str(args.audit_root / 'tactical-alignment-upper-ground-v1/fracture.tactical-ground.json.gz'),
             'proof': str(args.audit_root / 'tactical-alignment-upper-v1/fracture/candidate.json')}
    upper.pop('sha256')
    upper_entry, record = seal(upper, args.output, {}, suffix='.upper')
    catalog['maps']['fracture']['upperChart'] = upper_entry
    records.append(record)
    (args.output / 'height_catalog.json').write_text(json.dumps(catalog, indent=2))
    manifest = {'format': 'icarus-staged-tactical-assets-v1',
                'inventorySha256': sha(args.inventory.read_bytes()),
                'catalogSha256': sha((args.output / 'height_catalog.json').read_bytes()),
                'productionAssetsChanged': False,
                'limitations': ['Floor-chart policy and final all-map render acceptance remain pending.',
                                'Fracture uses a provisional selector; this catalog must not ship as is.'],
                'records': records}
    (args.output / 'provenance.json').write_text(json.dumps(manifest, indent=2))


if __name__ == '__main__':
    main()

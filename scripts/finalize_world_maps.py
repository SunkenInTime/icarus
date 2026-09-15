"""Compose approved scenery, pack bounded assets, and verify completed map bakes.

Run after the requested Art plane manifests and independent references exist.
The output is a candidate asset directory; activation and Flutter integration
checks remain separate. Source-ray outliers are retained for review.
"""
import argparse
from concurrent.futures import ThreadPoolExecutor, as_completed
import json
from pathlib import Path
import subprocess
import sys

from seal_world_plane_manifest import checked_policies, digest, read_json, seal_path, seal_plane_manifest, verify_plane_seal
from verify_world_runtime import read_map_names


def select_maps(rows, requested, required):
    entries = {}
    for row in rows:
        name = row['map']
        if name in entries:
            raise ValueError(f'Duplicate map row in source manifest: {name}')
        if name not in required:
            raise ValueError(f'Unknown map in source manifest: {name}')
        entries[name] = row
    names = list(requested) if requested is not None else list(required)
    if not names or len(set(names)) != len(names):
        raise ValueError('Requested maps must be nonempty and unique.')
    missing = [name for name in names if name not in entries]
    if missing:
        raise ValueError('Missing required source maps: ' + ', '.join(missing))
    return entries, names


def validate_reference(reference_path, base, entry, navigation_path, texture_properties_root=None):
    reference = read_json(reference_path)
    if reference.get('floorAlternativeCompletion') is not None:
        from verify_world_reference_metadata import verify_floor_completion
        verify_floor_completion(reference_path, navigation_path)
    source = reference.get('source', {})
    world = Path(entry['combinedWorldFolder'])
    expected = {'geometrySha256': entry['geometrySha256'], 'navigationSha256': base['source']['navigationSha256'],
                'metadataSha256': digest(world / 'geometry.json'), 'floorMeshSha256': digest(world / 'floor-mesh.json')}
    if reference.get('map') != base['map'] or reference.get('eyeHeightCm') != base['observerHeightCm']:
        raise ValueError('Independent reference map or standing height differs from the completed output.')
    for key, value in expected.items():
        if source.get(key) != value:
            raise ValueError(f'Independent reference source lineage differs: {key}')
    policy_path = Path(reference_path).with_suffix('.policies.json')
    if source.get('materialPoliciesSha256') != digest(policy_path):
        raise ValueError('Independent reference material policy fingerprint differs.')
    policy_document = read_json(policy_path)
    if policy_document.get('navigationSha256') != expected['navigationSha256'] or policy_document.get('walkable') != read_json(navigation_path).get('walkable'):
        raise ValueError('Independent reference observer walkability differs from the baked navigation.')
    checked_policies(read_json(world / 'geometry.json')['materials'], policy_document['policies'], texture_properties_root)
    origins, rays = reference.get('origins', []), reference.get('rays', [])
    directions = reference.get('sampling', {}).get('directions')
    summary = reference.get('summary', {})
    if (not origins or type(directions) is not int or directions <= 0 or len(rays) != len(origins) * directions
            or summary.get('origins') != len(origins) or summary.get('rays') != len(rays)):
        raise ValueError('The independent reference must contain every requested origin and direction.')
    if summary.get('alphaSamplingErrors') != {} or summary.get('floorAgreement') != len(origins):
        raise ValueError('Independent reference alpha sampling or observer ground checks are incomplete.')
    if any('planeReference' not in ray or 'planeElevationCm' not in ray for ray in rays):
        raise ValueError('Every independent ray needs its selected-plane 3D reference.')


def validate_packed_candidate(path, planes):
    """Resume only a complete packing of this exact sealed plane manifest."""
    path, planes = Path(path), Path(planes)
    data, source = read_json(path), read_json(planes)
    if (data.get('format') != 'chunked-v1' or data.get('map') != source['map'] or
            data.get('source') != {**source['source'], 'planeSealSha256': digest(seal_path(planes))}):
        raise ValueError('Existing packed candidate belongs to different sealed planes.')
    if [(row['elevationCm'], row['globalOrigins']) for row in data['layers']] != [
            (row['elevationCm'], row['globalOrigins']) for row in source['layers']]:
        raise ValueError('Existing packed candidate has different plane coverage.')
    if not data.get('chunks') or not data.get('navigationAsset'):
        raise ValueError('Existing packed candidate is missing geometry or navigation.')
    for record in [*data['chunks'], data['navigationAsset']]:
        child = (path.parent / record['asset']).resolve()
        if child.parent != path.parent.resolve():
            raise ValueError('Packed candidate asset escapes its directory.')
        if child.stat().st_size != record['compressedBytes'] or digest(child) != record['sha256']:
            raise ValueError('Existing packed candidate asset changed.')
    return data


def checked_source_evidence(entry):
    paths = []
    for record in entry.get('sourceEvidence', []):
        path = Path(record['path']).resolve()
        if path in paths or digest(path) != record['sha256']:
            raise ValueError('Additional source evidence changed or is duplicated.')
        paths.append(path)
    return paths


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('root', type=Path)
    parser.add_argument('supplement_manifest', type=Path)
    parser.add_argument('reference_folder', type=Path)
    parser.add_argument('output', type=Path)
    parser.add_argument('--maps', nargs='+')
    parser.add_argument('--workers', type=int, default=2)
    parser.add_argument('--layers-per-chunk', type=int, default=4,
                        help='Initial height group size; the packer still enforces its 2 MiB raw block limit.')
    parser.add_argument('--base-world-root', type=Path,
                        help='Source world used for the completed base planes; defaults to ROOT/corrected/world.')
    parser.add_argument('--base-plane-root', type=Path,
                        help='Completed base plane manifests; defaults to ROOT/final-planes.')
    parser.add_argument('--seal-existing', action='store_true',
                        help='Explicitly validate and seal completed base output after the bake.')
    parser.add_argument('--resume', action='store_true',
                        help='Reuse completed composition and packing only after verifying their seals and assets.')
    args = parser.parse_args()
    required = read_map_names(Path(__file__).resolve().parent.parent)
    try:
        entries, names = select_maps(json.loads(args.supplement_manifest.read_bytes()), args.maps, required)
    except ValueError as error:
        parser.error(str(error))
    if not 1 <= args.workers <= 4:
        parser.error('Use between one and four workers.')
    if not 1 <= args.layers_per_chunk <= 64:
        parser.error('Use between one and 64 layers per chunk.')
    intermediate = args.output / 'evidence'
    intermediate.mkdir(parents=True, exist_ok=True)
    script_folder = Path(__file__).parent
    base_world_root = args.base_world_root or args.root / 'corrected' / 'world'
    base_plane_root = args.base_plane_root or args.root / 'final-planes'
    texture_properties = args.root / 'materials' / 'texture-properties' / 'properties'

    def run(name):
        entry = entries[name]
        base = Path(entry.get('basePlaneManifest', base_plane_root / f'{name}.planes.json'))
        base_world = Path(entry.get('baseWorldFolder', base_world_root / name))
        base_audit = base.with_suffix('.audit.json')
        reference = Path(entry.get('referenceFile', args.reference_folder / f'{name}.json'))
        for path in (base, base_audit, reference):
            if not path.is_file():
                raise ValueError(f'{name}: required completed input is missing: {path}')
        audit = json.loads(base_audit.read_bytes())
        if audit['alphaSamplingFailures']:
            raise ValueError(f'{name}: the Art bake has unresolved alpha sampling failures.')
        base_data = json.loads(base.read_bytes())
        if base_data['source']['geometrySha256'] != entry['baseGeometrySha256']:
            raise ValueError(f'{name}: Art and supplement source lineage do not match.')
        validate_reference(reference, base_data, entry, base.with_name(name + '_navigation.json.gz'), texture_properties)
        evidence = checked_source_evidence(entry)
        composition_evidence = checked_source_evidence({
            'sourceEvidence': entry.get('compositionEvidence', [])})
        if args.seal_existing and not seal_path(base).exists():
            seal_plane_manifest(base, base_world, texture_properties, evidence_paths=evidence)
        base_seal = verify_plane_seal(base, world_folder=base_world)
        if any(base_seal['files'].get(str(path)) != digest(path) for path in evidence):
            raise ValueError('Completed base seal does not bind the required additional source evidence.')
        log_path = intermediate / f'{name}.log'
        planes = base if entry.get('baseOnly') else Path(entry.get(
            'composedPlaneManifest', intermediate / f'{name}.planes.json'))
        commands = []
        composition_exists = args.resume and planes != base and planes.is_file()
        if composition_exists:
            composed_seal = verify_plane_seal(planes, world_folder=entry['combinedWorldFolder'])
            if any(composed_seal['files'].get(str(path)) != digest(path) for path in composition_evidence):
                raise ValueError('Composition seal does not bind its required source evidence.')
            composed = read_json(planes)['source']
            if (composed.get('basePlaneSealSha256') != digest(seal_path(base)) or
                    composed.get('geometrySha256') != entry['geometrySha256'] or
                    composed.get('supplementMetadataSha256') != digest(Path(entry['supplementFolder']) / 'geometry.json') or
                    composed.get('supplementPoliciesSha256') != digest(Path(entry['supplementFolder']) / 'material-policies.json')):
                raise ValueError('Existing composition belongs to different approved source data.')
        if planes != base and not composition_exists:
            commands.append([sys.executable, str(script_folder / 'supplement_world_visibility.py'),
                str(base), entry['supplementFolder'], entry['combinedWorldFolder'], str(planes),
                '--texture-properties-root', str(texture_properties),
                *[value for path in composition_evidence for value in ('--evidence', str(path))]])
        packed = args.output / f'{name}_visibility.manifest.json'
        if args.resume and packed.is_file():
            if commands:
                raise ValueError('An existing packed candidate has no completed source composition.')
            validate_packed_candidate(packed, planes)
        else:
            commands.append([sys.executable, str(script_folder / 'pack_world_visibility.py'), str(planes), str(args.output),
                             '--layers-per-chunk', str(args.layers_per_chunk), '--force'])
        # Repeat the independent packed-ray comparison, even when assets resume.
        commands.append([sys.executable, str(script_folder / 'verify_baked_world_rays.py'),
                         str(packed), str(reference), str(intermediate / f'{name}-rays.json')])
        print(json.dumps({'map': name, 'status': 'started'}), flush=True)
        with log_path.open('w', encoding='utf-8') as log:
            for command in commands:
                subprocess.run(command, stdout=log, stderr=subprocess.STDOUT, check=True)
        report = json.loads((intermediate / f'{name}-rays.json').read_bytes())
        row = {'map': name, 'status': 'candidate-packed-and-compared', 'gameplayCertified': False,
               'summary': report['summary'], 'planeSummary': report.get('planeSummary'),
               'referenceReport': str(intermediate / f'{name}-rays.json'), 'log': str(log_path),
               'source': {'referenceSha256': digest(reference),
                          'referencePoliciesSha256': digest(reference.with_suffix('.policies.json')),
                          'planeSealSha256': digest(seal_path(planes)),
                          'packedManifestSha256': digest(args.output / f'{name}_visibility.manifest.json')}}
        print(json.dumps(row), flush=True)
        return row

    results = []
    with ThreadPoolExecutor(max_workers=args.workers) as executor:
        pending = {executor.submit(run, name): name for name in names}
        for future in as_completed(pending):
            try:
                results.append(future.result())
            except Exception as error:
                row = {'map': pending[future], 'status': 'failed', 'error': str(error)}
                results.append(row)
                print(json.dumps(row), flush=True)
    results.sort(key=lambda row: names.index(row['map']))
    batch = {'scope': 'all_maps' if args.maps is None else 'explicit_subset',
             'allMapCoverageComplete': set(names) == set(required) and not any(row['status'] == 'failed' for row in results),
             'requestedMaps': names, 'requiredMaps': required, 'gameplayCertified': False, 'maps': results}
    (intermediate / 'batch-manifest.json').write_text(json.dumps(batch, indent=2), encoding='utf-8')
    if any(row['status'] == 'failed' for row in results):
        raise SystemExit(1)


if __name__ == '__main__':
    main()

"""Run the unchanged full-domain comparison on both sides with checkpoints."""
import argparse
import hashlib
import json
from pathlib import Path

import numpy as np

from audit_all_map_gameplay_levels import ROOT, read
from checkpoint_floor_measurements import checkpointed_measurements
from verify_icebox_regional_floors import compare, BOUNDARY_TOLERANCE_SVG, OVERLAY_PRECISION_SVG


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def measure_side(obligation):
    side, source_path, candidate_path, matrix = obligation
    source = read(Path(source_path))
    print(f'Comparing {len(source["domains"])} complete {side} domains.', flush=True)
    rows = compare(source, read(Path(candidate_path)), np.asarray(matrix), side)
    return dict(row=dict(side=side, domainChecks=len(rows),
        failedDomainChecks=sum(r['status'] != 'passed' for r in rows),
        failedDefaultDomainChecks=sum(r['defaultStatus'] != 'passed' for r in rows)), checks=rows)


def verify(source_dir, candidate_dir, map_name_override=None):
    target = candidate_dir/'regional-floor-comparison.json'
    if target.exists():
        raise ValueError('Preserve the existing comparison report.')
    source_path = source_dir/'regional-floors.json'
    source = read(source_path)
    assert len({d['id'] for d in source['domains']}) == len(source['domains'])
    declared_map = read(source_dir/'source-inventory.json').get('map')
    if declared_map and map_name_override and declared_map != map_name_override:
        raise ValueError('Explicit map does not match the source inventory')
    map_name = declared_map or map_name_override
    if map_name not in ['abyss', 'ascent', 'bind', 'breeze', 'corrode', 'fracture',
                        'haven', 'icebox', 'lotus', 'pearl', 'split', 'summit', 'sunset']:
        raise ValueError('Source inventory needs a known map, or an explicit --map for legacy inventories')
    alignment_path = ROOT/f'tactical-alignment-sides-v1/{map_name}.json'
    alignment = read(alignment_path)
    assets = {side: candidate_dir/f'candidate-{side}.json.gz' for side in ['attack', 'defense']}
    dependencies = [Path(__file__), *[Path(__file__).with_name(name) for name in [
        'verify_icebox_regional_floors.py', 'checkpoint_floor_measurements.py',
        'audit_all_map_gameplay_levels.py', 'build_all_map_gameplay_supports.py',
        'compile_reviewed_svg_height_map.py', 'polygonal_area.py', 'source_geometry_projection.py']]]
    hashes = {str(p): sha(p) for p in [source_path, alignment_path, *assets.values(), *dependencies]}
    fingerprint = hashlib.sha256(json.dumps(hashes, sort_keys=True).encode()).hexdigest()
    archive = candidate_dir/'domain-side-checkpoints'/fingerprint/'algorithms'
    archive.mkdir(parents=True, exist_ok=True)
    for path in dependencies:
        copy = archive/path.name
        if copy.exists():
            assert copy.read_bytes() == path.read_bytes()
        else:
            copy.write_bytes(path.read_bytes())
    obligations = [(side, str(source_path), str(path), alignment[f'nativeTo{side.title()}Svg'])
        for side, path in assets.items()]
    results = checkpointed_measurements(obligations, measure_side, (),
        candidate_dir/'domain-side-checkpoints', fingerprint, workers=2)
    rows = [row for result in results for row in result['checks']]
    assert {(r['id'], r['side']) for r in rows} == {
        (d['id'], side) for d in source['domains'] for side in assets}
    failed = sum(r['status'] != 'passed' for r in rows)
    defaults = sum(r['defaultStatus'] != 'passed' for r in rows)
    report = dict(map=map_name, status='passed' if not failed and not defaults else 'floor-differences',
        heightToleranceMeters=.02, boundaryToleranceSvg=BOUNDARY_TOLERANCE_SVG,
        overlayPrecisionSvg=OVERLAY_PRECISION_SVG, sourceSha256=sha(source_path),
        assetSha256={side: sha(path) for side, path in assets.items()},
        algorithmSha256=sha(Path(__file__).with_name('verify_icebox_regional_floors.py')),
        orchestratorSha256=sha(Path(__file__)), inputsSha256=hashes, checkpointFingerprint=fingerprint,
        domainChecks=len(rows), failedDomainChecks=failed, failedDefaultDomainChecks=defaults, rows=rows)
    target.write_text(json.dumps(report, indent=2)+'\n')
    print(json.dumps({k: v for k, v in report.items() if k not in ['rows', 'inputsSha256']}), flush=True)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', type=Path, required=True)
    parser.add_argument('--candidate-dir', type=Path, required=True)
    parser.add_argument('--map', dest='map_name_override')
    args = parser.parse_args()
    verify(args.source, args.candidate_dir, args.map_name_override)

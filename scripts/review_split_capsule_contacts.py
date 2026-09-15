"""Strengthen two empty Split standing decisions with exact buried contacts.

The raw source run retains its complete measurements and analytic clearance.
This review changes no domain, collider, triangle, or physical dimension. It
replaces the need to rely on curved standing patches for the two named records.
"""
import argparse
import copy
import hashlib
import json
from pathlib import Path
import shutil
import numpy as np
from gameplay_standing_volumes import StandingVolumes
from native_capsule_collision import capsule_parts
from native_capsule_standing import blocked_contact_prism


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def apply(source_dir, output):
    if output.exists():
        raise ValueError('Preserve previous source reviews; use a new folder')
    source_path = source_dir/'regional-floors.json'
    source = json.loads(source_path.read_bytes())
    inventory = json.loads((source_dir/'source-inventory.json').read_bytes())
    assert inventory['map'] == 'split'
    assert source['sourceInventorySha256'] == sha(source_dir/'source-inventory.json')
    assert not source['unresolvedInfluencingCollision']
    rows = json.loads((source_dir/'source-colliders.json').read_bytes())
    selected = {r['sourceObject']: r for r in rows if r.get('sourceObject') in [1339, 1347]}
    assert set(selected) == {1339, 1347}
    solids = StandingVolumes('split')
    result = copy.deepcopy(source)
    decisions = []
    for oid, row in selected.items():
        shape = row['analyticCapsule']
        assert capsule_parts(dict(AggGeom=dict(SphylElems=[shape['sourceElement']])),
            np.asarray(shape['sourceMatrix'])) == [shape]
        proof = blocked_contact_prism(shape, solids)
        assert proof and any(v['sourceCollision'] == '/Bonsai_BVPawn/BP_BlockingVolume11/Cube#0'
            for v in proof['containingVolumes'])
        assert not any(d.get('sourceObject') == oid for d in source['domains'])
        collider_index = rows.index(row)
        assert not any(any(face[0] == collider_index for face in d.get('sourceFaces', []))
            for d in source['domains']), 'An experimental curved patch became a standing domain'
        original = [r for r in source['sourceRows'] if r.get('sourceObject') == oid]
        changed = [r for r in result['sourceRows'] if r.get('sourceObject') == oid]
        assert len(original) == len(changed) == 1
        assert original[0]['status'] == 'no-clear-standing-domain' and original[0]['domains'] == 0
        changed[0]['exactAnalyticStandingExclusion'] = proof
        decisions.append(dict(sourceObject=oid, analyticCapsule=shape, proof=proof,
            priorStandingDomains=0, finalStandingDomains=0,
            reason='Every potentially walkable contact lies at least 8.7 mm inside native player-blocking solid. The touching player necessarily penetrates that solid. The complete curved body remains active for clearance.'))
    assert result['domains'] == source['domains']
    for before, after in zip(source['sourceRows'], result['sourceRows']):
        clean = dict(after)
        clean.pop('exactAnalyticStandingExclusion', None)
        assert clean == before
    output.mkdir(parents=True)
    names = ['source-inventory.json', 'source-colliders.json', 'source-colliders.npz',
        'collision-accounting.json', 'collision-algorithm.py']
    for name in names:
        shutil.copyfile(source_dir/name, output/name)
    for name in ['algorithm-sources', 'inventory-algorithms']:
        shutil.copytree(source_dir/name, output/name)
    shutil.copyfile(source_path, output/'raw-physical-floors.json')
    algorithms = [Path(__file__), Path(__file__).with_name('native_capsule_standing.py'),
        Path(__file__).with_name('native_capsule_collision.py'),
        Path(__file__).with_name('gameplay_standing_volumes.py')]
    archive = output/'exact-contact-review-algorithms'
    archive.mkdir()
    for path in algorithms:
        shutil.copyfile(path, archive/path.name)
    report = dict(map='split', status='passed', rawSourceSha256=sha(source_path),
        sourceInventorySha256=sha(source_dir/'source-inventory.json'),
        sourceCollidersSha256=sha(source_dir/'source-colliders.json'),
        sourceColliderTrianglesSha256=sha(source_dir/'source-colliders.npz'),
        algorithmSha256={p.name: sha(p) for p in algorithms},
        decisions=decisions, domainsChanged=0, collidersChanged=0,
        scope='Exact standing exclusion for both remaining curved candidates; all full-domain measurements and all analytic clearance bodies are preserved.')
    path = output/'exact-capsule-contact-review.json'
    path.write_text(json.dumps(report, indent=2)+'\n')
    result.update(status='source-domains-with-exact-capsule-contact-review',
        rawPhysicalSourceSha256=sha(source_path), exactCapsuleContactReviewSha256=sha(path))
    (output/'regional-floors.json').write_text(json.dumps(result, indent=2)+'\n')
    print(json.dumps(dict(status='passed', exactContactDecisions=2, domainsChanged=0,
        sourceSha256=sha(output/'regional-floors.json'))))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    apply(args.source, args.output)

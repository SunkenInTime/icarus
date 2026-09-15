"""Frozen Ascent renderer contact directions and exact source first hits."""
import bisect
import gzip
import hashlib
import json
from pathlib import Path

import numpy as np

from audit_wall_contact_pixels import PhysicalGeometry
from native_reference_cast import NativeReferenceModel
from tactical_alignment_composite import IndexedTriangles

R = Path('E:/IcarusWorldAudit/2026-09-06/tactical-visibility-revision')
C = R/'ascent-connected-component5-candidate-v5'
F = R/'ascent-component5-contact-v5'
manifest = json.loads((F/'manifest.json').read_text())
warp = json.loads(gzip.decompress(Path(manifest['displayWarpFile']).read_bytes()))
source = np.array(warp['sourceNativeMeters']).reshape(-1, 2)
target = np.array(warp['targetAttackSvg']).reshape(-1, 2)
cells = np.array(warp['triangles']).reshape(-1, 3)
index = IndexedTriangles(source, cells)


def display(xy):
    xy = np.atleast_2d(xy)
    cs = index.find_simplex(xy)
    assert (cs >= 0).all()
    transforms = index.transform[cs]
    uv = np.einsum('nij,nj->ni', transforms[:, :2], xy-transforms[:, 2])
    return np.einsum('ni,nij->nj', np.c_[uv, 1-uv.sum(1)], target[cells[cs]])


caster = NativeReferenceModel(C/'ascent.height.bin.gz', R/'native-tactical-rays-build/Release/tactical_reference_cast.dll')
chains = [np.load(p)['sourceFaces'] for p in [C/'correspondence.npz', R/'global-ground-complete-v2/ascent/correspondence.npz', R/'full-height-input-v1/ascent/source-correspondence.npz']]
meta = Path('E:/IcarusWorldAudit/2026-09-06/supplemented-v2/world/ascent/geometry.json')
objects = json.loads(meta.read_text())['objects']
starts = [o['firstFace'] for o in objects]
fixtures = {f['id']: f for f in json.loads((C/'render-fixtures/ascent-fixtures.json').read_text())['cases']}
records = []
for case_id in ('span-144-center', 'span-145-center', 'span-149-end-corner', 'span-150-center', 'span-150-start-corner'):
    row = next(r for r in manifest['cases'] if r['side']=='attack' and r['id']==case_id)
    q = np.array(row['query'])
    geometry = PhysicalGeometry(warp, row, np.fromfile(row['prefix']+'-shadow.f32', dtype='<f4'))
    a,b = np.array(fixtures[case_id]['boundedTargetLineSvg'])
    tangent = (b-a)/np.linalg.norm(b-a)
    normal = np.array([-tangent[1], tangent[0]])
    origin = display(q[:2])[0]
    if (origin-a)@normal < 0:
        normal = -normal
    samples = []
    for t in np.arange(.025, np.linalg.norm(b-a), .05):
        point = a+tangent*t
        if not geometry.in_frustum(point, margin=False)[0]:
            continue
        goal = geometry.native(point)[0]
        delta = goal-q[:2]
        end = q[:2]+delta*(1+1/np.linalg.norm(delta))
        hit = caster.cast(q[:3], np.r_[end, q[2]])
        sample = dict(alongSvg=float(t), pointSvg=point.tolist(),
                      meshClearAtInward005=bool(geometry.clear(point+normal*.005)[0]),
                      meshClearAtOutward005=bool(geometry.clear(point-normal*.005)[0]))
        if hit:
            mapped = display(hit['point'][:2])[0]
            ids = [hit['face']]
            for chain in chains:
                ids.append(int(chain[ids[-1]]))
                assert ids[-1] >= 0
            oi = bisect.bisect_right(starts, ids[-1])-1
            obj = objects[oi]
            assert obj['firstFace'] <= ids[-1] < obj['firstFace']+obj['faceCount']
            sample.update(hitSvg=mapped.tolist(), hitNative=hit['point'],
                          hitNormalOffsetSvg=float((mapped-point)@normal),
                          hitTangentSvg=float((mapped-a)@tangent), faceChain=ids,
                          sourceObject=oi, sourcePath=obj['path'])
        else:
            sample['clearPastLine'] = True
        samples.append(sample)
    records.append(dict(id=case_id, authoredEnds=[a.tolist(),b.tolist()],
                        observerSvg=origin.tolist(), query=q.tolist(), samples=samples))
    groups = sorted({s['sourceObject'] for s in samples if s.get('hitNormalOffsetSvg',0)>.05})
    print(case_id, len(samples), 'samples, early source objects', groups)
output = R/'ascent-component5-control-v5-evidence/frozen-contact-first-hits.json'
output.write_text(json.dumps(dict(scope=__doc__, limitations='Current source-ground-relative eye and frozen two-sided source policy; not an absolute-world-Z or gameplay certificate.', sourcePackSha256=hashlib.sha256((C/'ascent.height.bin.gz').read_bytes()).hexdigest(), sourceMetadata=dict(path=str(meta),sha256=hashlib.sha256(meta.read_bytes()).hexdigest()), records=records),indent=2))

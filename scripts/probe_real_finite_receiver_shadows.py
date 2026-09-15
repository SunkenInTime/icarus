"""Conditional real-source receiver shadows from frozen Split observers.

Support candidates are retained separately; this does not choose ambiguous
target layers or certify walking support. Masked/coplanar cases remain pending.
"""
import argparse
import hashlib
import json
from pathlib import Path
import time

import numpy as np
import shapely

from build_global_tactical_candidate import GroundField
from finite_receiver_shadows import Receiver, build_shadows, renderer_mesh_checked
from finite_shadow_broadphase import candidates, swept_bounds
from native_reference_cast import NativeReferenceModel
from probe_static_floor_sections import query_box


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('revision', type=Path)
    parser.add_argument('output', type=Path)
    args = parser.parse_args()
    r = args.revision
    args.output.mkdir(parents=True, exist_ok=False)
    complete = r/'split-complete-control-original-height-v29-v2'
    pack = complete/'split.height.bin.gz'
    gate_path = complete/'root-independent-composition-review.json'
    gate = json.loads(gate_path.read_bytes())
    assert gate['passed'] and sha(pack) == gate['completePackSha256']
    scene_path = r/'frozen-split-app-scene-v29-run1/manifest.json'
    scene = json.loads(scene_path.read_bytes())
    query_rows = next(row for row in scene['records'] if row['side'] == 'attack')['sourceQueries']
    config_path = Path(scene['configPath'])
    config = json.loads(config_path.read_bytes())['maps']['split']
    field_path = Path(config['groundFieldFile'])
    field = GroundField(field_path)
    support_meta_path = r/'source-floor-support-all-walkable-v1/split.floor-support.json'
    support_meta = json.loads(support_meta_path.read_bytes())
    support_path = support_meta_path.parent/support_meta['dataFile']
    assert sha(support_path) == support_meta['dataSha256']
    with np.load(support_path) as data:
        points = data['vertices'][data['triangles']]
        source_ids = data['sourceFaces']
    eligible = np.flatnonzero(source_ids >= 0)
    shapes = shapely.polygons(points[eligible, :, :2])
    tree = shapely.STRtree(shapes)
    model = NativeReferenceModel(pack, r/'native-tactical-rays-build/Release/tactical_reference_cast.dll')
    records, fixtures = [], []
    for agent_index, label in [(4, 'Clove'), (6, 'Iso'), (7, 'Viper')]:
        q = np.array(query_rows[agent_index])
        eye = q[:3].copy()
        eye[2] += field.heights(q[None, :2])[0]
        seen = set()
        for distance in [3., 6., 10.]:
            target_xy = q[:2] + distance*q[3:5]
            support_rows = eligible[tree.query(shapely.Point(target_xy), predicate='intersects')]
            all_candidates = []
            for support_id in support_rows:
                triangle = points[support_id]
                plane = np.linalg.solve(np.c_[triangle[:, :2], np.ones(3)], triangle[:, 2])
                all_candidates.append(dict(supportId=int(support_id), sourceFace=int(source_ids[support_id]),
                                           height=float(target_xy@plane[:2]+plane[2]), plane=plane.tolist()))
            for candidate in all_candidates:
                support_id = candidate['supportId']
                if support_id in seen:
                    continue
                seen.add(support_id)
                receiver = Receiver(points[support_id, :, :2], np.array(candidate['plane']))
                low, high = swept_bounds(eye, receiver)
                ids = query_box(model, low, high)
                xyz = model.arrays['vertices'][model.arrays['faces'][ids]]
                keep = candidates(eye, receiver, xyz.min(1), xyz.max(1))
                ids, xyz = ids[keep], xyz[keep]
                masks = model.arrays['faceMasks'][ids]
                opaque = masks < 0
                begin = time.perf_counter()
                shadows, pending = build_shadows(eye, xyz[opaque], [receiver])
                projection_ms = (time.perf_counter()-begin)*1000
                opaque_ids = ids[opaque]
                for item in pending:
                    item['sourceFace'] = int(opaque_ids[item['sourceFace']])
                mesh, output_fallback = renderer_mesh_checked(eye, shadows)
                for item in output_fallback:
                    item['sourceFace'] = int(opaque_ids[item['sourceFace']])
                pending.extend(output_fallback)
                polygon = shapely.union_all([shapely.Polygon(item['polygon']) for item in shadows])
                ray_records = []
                for u in [.13, .29, .47, .67]:
                    for v in [.17, .38, .61]:
                        if u+v >= .97:
                            continue
                        xy = np.array([1-u-v, u, v])@receiver.footprint
                        target = receiver.lift(xy)
                        hit = model.cast(eye, target)
                        covered = bool(shapely.covers(polygon, shapely.Point(xy)))
                        ray_records.append(dict(target=target.tolist(), sourceHit=hit,
                                                projectedOpaqueBlocked=covered,
                                                differsFromAlphaAwareSource=covered != (hit is not None)))
                fixture_id = f'{label.lower()}-ahead{distance:g}-support{support_id}'
                np.savez_compressed(args.output/f'{fixture_id}.npz', sourceTriangles=xyz,
                                    sourceFaceIds=ids, faceMasks=masks, observer=eye,
                                    receiverFootprint=receiver.footprint, receiverPlane=receiver.floor_plane,
                                    shadowTrianglesRelativeXY=mesh)
                row = dict(id=fixture_id, agent=label, originalQuery=q.tolist(), originalEye=eye.tolist(),
                           aheadMeters=distance, probeXY=target_xy.tolist(), supportCandidate=candidate,
                           allOverlappingSupportCandidates=all_candidates, explicitTargetLayerNotChosen=True,
                           sourceCandidates=len(ids), opaqueCandidates=int(opaque.sum()), maskedFallbackFaces=ids[~opaque].tolist(),
                           explicitContactFallback=pending, generatedShadowPolygons=len(shadows),
                           pythonProjectionMilliseconds=projection_ms, rays=ray_records,
                           projectedInputRawBytes=int(xyz.nbytes+masks.nbytes+receiver.footprint.nbytes+receiver.floor_plane.nbytes),
                           fixtureBytes=(args.output/f'{fixture_id}.npz').stat().st_size)
                records.append(row)
                print(f'{fixture_id}: faces{len(ids)}, masked{int((~opaque).sum())}, contactFallback{len(pending)}, {projection_ms:.2f}ms', flush=True)
            if not len(support_rows):
                records.append(dict(agent=label, aheadMeters=distance, probeXY=target_xy.tolist(),
                                    explicitTargetLayerNotChosen=True, status='no-source-support-footprint-at-derived-target'))
    report = dict(scope=__doc__, completePackSha256=sha(pack), compositionGateSha256=sha(gate_path),
                  frozenSceneManifestSha256=sha(scene_path), originalFixtureSha256=scene['fixtureSha256'],
                  supportSha256=sha(support_path), groundFieldSha256=sha(field_path),
                  supportPolicy=support_meta['policy'], records=records,
                  limitations=['Target samples are derived from frozen observer headings at3/6/10m, not live-game captures.',
                               'Each existing source-support candidate is conditional; no ambiguous layer is silently selected.',
                               'Complete pack means complete existing control domain; pre-control exclusions remain absent.',
                               'Masked and coplanar faces need explicit fallback; alpha-aware source comparisons are diagnostic.',
                               'Python per-case projection timings are single-run workload observations, not native/GPU or refresh-rate measurements.'],
                  sourceSha256={name:sha(Path(__file__).with_name(name)) for name in
                                ['probe_real_finite_receiver_shadows.py','finite_receiver_shadows.py','finite_shadow_broadphase.py']})
    (args.output/'report.json').write_text(json.dumps(report, indent=2)+'\n')


if __name__ == '__main__':
    main()

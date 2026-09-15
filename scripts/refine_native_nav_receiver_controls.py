"""Compare each nearby source floor against literal native-nav standing Z.

Frozen navigation-interior XY and physical observer stay unchanged. Competing
source planes remain separate hypotheses; none is averaged or selected silently.
"""
import argparse
import json
from pathlib import Path
import time

import numpy as np
import shapely

from finite_receiver_shadows import Receiver, build_shadows, renderer_mesh_checked, clip
from finite_shadow_broadphase import candidates, swept_bounds
from native_reference_cast import NativeReferenceModel
from probe_real_receiver_room_controls import sha
from probe_static_floor_sections import query_box


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('revision', type=Path)
    parser.add_argument('output', type=Path)
    args = parser.parse_args()
    r, out = args.revision, args.output
    out.mkdir(parents=True, exist_ok=False)
    parent_path = r/'native-nav-standing-room-controls-v1/report.json'
    parent = json.loads(parent_path.read_bytes())
    pack = r/'split-complete-control-original-height-v29-v2/split.height.bin.gz'
    assert sha(pack) == parent['completePackSha256']
    meta_path = r/'source-floor-support-all-walkable-v1/split.floor-support.json'
    meta = json.loads(meta_path.read_bytes())
    support_path = meta_path.parent/meta['dataFile']
    assert sha(support_path) == parent['supportSha256'] == meta['dataSha256']
    with np.load(support_path) as data:
        support = data['vertices'][data['triangles']]
    model = NativeReferenceModel(pack, r/'native-tactical-rays-build/Release/tactical_reference_cast.dll')
    records = []
    for original in parent['records']:
        control = original['control']
        eye = np.array(original['originalEye'])
        nav_tri = np.array(original['nativeNavVertices'])
        nav_plane = np.linalg.solve(np.c_[nav_tri[:, :2], np.ones(3)], nav_tri[:, 2])
        xy = np.array(control['nativeNavFeet'][:2])
        for hypothesis in control['nearSourceSupport']:
            sid = hypothesis['supportId']
            plane = np.array(hypothesis['plane'])
            shape = shapely.intersection(shapely.Polygon(nav_tri[:, :2]), shapely.Polygon(support[sid, :, :2]))
            if shape.geom_type != 'Polygon' or shape.area <= 0:
                raise ValueError('Frozen interior source association has no positive-area nav overlap')
            polygon = np.array(shape.exterior.coords[:-1])
            # Restrict the candidate plane domain to points where the native
            # layer association remains within the declared15cm band.
            difference = plane-nav_plane
            polygon = clip(polygon, np.r_[-difference[:2], .15-difference[2]])
            polygon = clip(polygon, np.r_[difference[:2], .15+difference[2]])
            assert len(polygon) >= 3 and shapely.covers(shapely.Polygon(polygon), shapely.Point(xy))
            receiver = Receiver(polygon, plane)
            target = receiver.lift(xy)
            feet = target-[0, 0, 1.75]
            body = []
            for dx, dy in [(0, 0), (.12, 0), (-.12, 0), (0, .12), (0, -.12)]:
                offset = np.array([dx, dy, 0])
                start, end = feet+offset+[0, 0, .2], target+offset
                hit = model.cast(start, end)
                body.append(dict(start=start.tolist(), end=end.tolist(), hit=hit,
                                 withinSourceFootprint=bool(shapely.covers(shapely.Polygon(support[sid, :, :2]), shapely.Point((xy+offset[:2]))))))
            head_hit = model.cast(eye, target)
            floor_hit = model.cast(eye, feet)
            low, high = swept_bounds(eye, receiver)
            ids = query_box(model, low, high)
            xyz = model.arrays['vertices'][model.arrays['faces'][ids]]
            keep = candidates(eye, receiver, xyz.min(1), xyz.max(1))
            ids, xyz = ids[keep], xyz[keep]
            masks = model.arrays['faceMasks'][ids]; opaque = masks < 0
            begin = time.perf_counter()
            shadows, pending = build_shadows(eye, xyz[opaque], [receiver])
            cost = (time.perf_counter()-begin)*1000
            for item in pending:
                item['sourceFace'] = int(ids[opaque][item['sourceFace']])
            mesh, output_fallback = renderer_mesh_checked(eye, shadows)
            for item in output_fallback:
                item['sourceFace'] = int(ids[opaque][item['sourceFace']])
            pending.extend(output_fallback)
            projected_shape = shapely.union_all([shapely.Polygon(x['polygon']) for x in shadows])
            projected = bool(shapely.covers(projected_shape, shapely.Point(xy)))
            fixture_id = original['id']+f'-source{sid}'
            np.savez_compressed(out/f'{fixture_id}.npz', sourceTriangles=xyz, sourceFaceIds=ids, faceMasks=masks,
                                observer=eye, receiverFootprint=receiver.footprint, receiverPlane=plane,
                                shadowTrianglesRelativeXY=mesh)
            records.append(dict(id=fixture_id, agent=original['agent'], originalEye=eye.tolist(), query=original['query'],
                                originalNavControlId=original['id'], nativeNavFeet=control['nativeNavFeet'], sourceFeet=feet.tolist(),
                                navTarget=control['target'], target=target.tolist(), sourceSupportHypothesis=hypothesis,
                                allNearbySourceHypotheses=control['nearSourceSupport'], allSourceSupportAlternatives=control['allSourceSupportAlternatives'],
                                navBodyProbes=control['bodyProbes'], sourceBodyProbes=body,
                                sourceBodyClear=all(x['hit'] is None for x in body),
                                navHeadHit=control['sourceHit'], sourceHeadHit=head_hit, sourceFloorHit=floor_hit,
                                headOutcomeChangedFromNativeNav=(head_hit is None) != (control['sourceHit'] is None),
                                receiverFootprint=polygon.tolist(), receiverPlane=plane.tolist(), sourceCandidates=len(ids),
                                maskedFallbackFaces=ids[~opaque].tolist(), contactFallback=pending, pythonProjectionMilliseconds=cost,
                                rays=[dict(target=target.tolist(), sourceHit=head_hit, projectedOpaqueBlocked=projected,
                                           differsFromAlphaAwareSource=projected != (head_hit is not None))]))
            print(f'{fixture_id}: headChanged={records[-1]["headOutcomeChangedFromNativeNav"]}, bodyClear={records[-1]["sourceBodyClear"]}, differs={records[-1]["rays"][0]["differsFromAlphaAwareSource"]}', flush=True)
    report = dict(scope=__doc__, completePackSha256=sha(pack), parentNativeNavReportSha256=sha(parent_path),
                  supportSha256=sha(support_path), scriptSha256=sha(Path(__file__)),
                  projectionSha256=sha(Path(__file__).with_name('finite_receiver_shadows.py')), records=records,
                  summary=dict(controls=len(records), sourceBodyBlocked=sum(not x['sourceBodyClear'] for x in records),
                               headOutcomeChanges=sum(x['headOutcomeChangedFromNativeNav'] for x in records),
                               projectionDifferences=sum(x['rays'][0]['differsFromAlphaAwareSource'] for x in records)),
                  limitations=['Each nearby source plane is a separate hypothesis at fixed native-nav interior XY; no competing height is silently chosen.',
                               'Native nav supplies the valid-layer/interior reference; source plane supplies the refined target height.',
                               'Five body rays are not a complete pawn-capsule or foot-support test; lateral rays outside this one source footprint are identified.',
                               'Receiver polygons are nav/source intersections restricted to15cm height agreement, not the entire walkable map.',
                               'Masked/contact fallback remains pending even if frozen head rays agree; this does not certify app or live game behavior.'])
    (out/'report.json').write_text(json.dumps(report, indent=2)+'\n')


if __name__ == '__main__':
    main()

"""Standing targets from original extracted navigation, with source association.

Native Recast Z is used literally; source-refined floor data never supplies the
target height. Interior and body probes strengthen these diagnostic positions
without claiming that they recover the full game's pawn collision rules.
"""
import argparse
import json
from pathlib import Path
import time

import numpy as np
import shapely

from build_global_tactical_candidate import GroundField
from finite_receiver_shadows import Receiver, build_shadows, renderer_mesh_checked
from finite_shadow_broadphase import candidates, swept_bounds
from native_reference_cast import NativeReferenceModel
from probe_real_receiver_room_controls import in_cone, sha
from probe_static_floor_sections import query_box


def plane_of(tri):
    return np.linalg.solve(np.c_[tri[:, :2], np.ones(3)], tri[:, 2])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('revision', type=Path)
    parser.add_argument('output', type=Path)
    args = parser.parse_args()
    r, out = args.revision, args.output
    out.mkdir(parents=True, exist_ok=False)
    pack = r/'split-complete-control-original-height-v29-v2/split.height.bin.gz'
    gate_path = pack.parent/'root-independent-composition-review.json'
    gate = json.loads(gate_path.read_bytes())
    assert gate['passed'] and sha(pack) == gate['completePackSha256']
    scene_path = r/'frozen-split-app-scene-v29-run1/manifest.json'
    scene = json.loads(scene_path.read_bytes())
    queries = next(x for x in scene['records'] if x['side'] == 'attack')['sourceQueries']
    config = json.loads(Path(scene['configPath']).read_bytes())['maps']['split']
    ground_path = Path(config['groundFieldFile'])
    ground = GroundField(ground_path)
    nav_path = r.parent/'nav/baked/split_navigation.json'
    raw_path = r.parent/'nav/baked/split_source_xyz.json'
    nav, raw = json.loads(nav_path.read_bytes()), json.loads(raw_path.read_bytes())
    assert raw['navigationSha256'] == sha(nav_path)
    vertices = np.array(raw['vertices'], dtype=float).reshape(-1, 3)/100
    vertices[:, 1] *= -1
    refs = np.array(raw['triangles']).reshape(-1, 4)
    nav_tris = vertices[refs[:, 1:]]
    walkable = np.array(nav['walkable'])[refs[:, 0]]
    nav_shapes = shapely.polygons(nav_tris[:, :, :2])
    eligible = np.flatnonzero(walkable & (shapely.area(nav_shapes) > 1e-10))
    parent_shapes = {int(i): shapely.Polygon(vertices[raw['polygons'][i], :2]) for i in np.unique(refs[eligible, 0])}
    meta_path = r/'source-floor-support-all-walkable-v1/split.floor-support.json'
    meta = json.loads(meta_path.read_bytes())
    support_path = meta_path.parent/meta['dataFile']
    assert sha(support_path) == meta['dataSha256']
    with np.load(support_path) as data:
        support = data['vertices'][data['triangles']]
        source_ids = data['sourceFaces']
    n = np.cross(support[:, 1]-support[:, 0], support[:, 2]-support[:, 0])
    support_ids = np.flatnonzero((source_ids >= 0) & (abs(n[:, 2]) > 1e-12))
    tree = shapely.STRtree(shapely.polygons(support[support_ids, :, :2]))
    model = NativeReferenceModel(pack, r/'native-tactical-rays-build/Release/tactical_reference_cast.dll')
    records, searches = [], []
    for agent, name in [(4, 'Clove'), (6, 'Iso'), (7, 'Viper')]:
        q = np.array(queries[agent])
        eye = q[:3].copy(); eye[2] += ground.heights(q[None, :2])[0]
        proposals = []
        for tid in eligible:
            # These strictly interior barycentric points also exercise narrow
            # parents whose center lies outside the frozen cone.
            for bary in [[1/3]*3, [.6, .2, .2], [.2, .6, .2], [.2, .2, .6]]:
                feet = np.array(bary)@nav_tris[tid]
                if in_cone(feet[:2], q):
                    proposals.append((float(np.linalg.norm(feet[:2]-eye[:2])), int(tid), feet))
        proposals.sort(key=lambda x: (x[0], x[1], x[2][0], x[2][1]))
        counts = {k: 0 for k in ['proposals', 'interiorRejected', 'noNearSource', 'bodyBlocked', 'qualified', 'opaqueBlocked', 'clear', 'floorSteepBlockedHeadClear', 'horizontalSteepBlockedHeadClear']}
        selected, bins = [], set()
        for distance, tid, feet in proposals:
            counts['proposals'] += 1
            parent = int(refs[tid, 0])
            point = shapely.Point(feet[:2])
            margin = shapely.distance(point, parent_shapes[parent].boundary)
            if not shapely.contains(parent_shapes[parent], point) or margin < .15:
                counts['interiorRejected'] += 1; continue
            associations = []
            for sid in support_ids[tree.query(point, predicate='intersects')]:
                coeff = plane_of(support[sid])
                height = float(feet[:2]@coeff[:2]+coeff[2])
                associations.append(dict(supportId=int(sid), sourceFace=int(source_ids[sid]), floorHeight=height,
                                         sourceMinusNativeNavMeters=height-float(feet[2]), plane=coeff.tolist()))
            near = [x for x in associations if abs(x['sourceMinusNativeNavMeters']) <= .15]
            if not near:
                counts['noNearSource'] += 1; continue
            target = feet + [0, 0, 1.75]
            body = []
            for dx, dy in [(0, 0), (.12, 0), (-.12, 0), (0, .12), (0, -.12)]:
                start = feet+[dx, dy, .2]
                end = target+[dx, dy, 0]
                hit = model.cast(start, end)
                body.append(dict(start=start.tolist(), end=end.tolist(), hit=hit))
            if any(x['hit'] is not None for x in body):
                counts['bodyBlocked'] += 1; continue
            counts['qualified'] += 1
            hit = model.cast(eye, target)
            floor_hit = horizontal_hit = None
            if hit is None:
                counts['clear'] += 1
                floor_hit = model.cast(eye, feet)
                horizontal_hit = model.cast(eye, np.r_[feet[:2], eye[2]])
                kinds = []
                if floor_hit and not floor_hit['masked'] and abs(floor_hit['normal'][2]) < .6 and floor_hit['distanceMeters'] < np.linalg.norm(feet-eye)-.25:
                    kinds.append('floorSteepBlockedHeadClear')
                if horizontal_hit and not horizontal_hit['masked'] and abs(horizontal_hit['normal'][2]) < .6 and horizontal_hit['distanceMeters'] < distance-.25:
                    kinds.append('horizontalSteepBlockedHeadClear')
                for kind in kinds:
                    counts[kind] += 1
            elif not hit['masked'] and abs(hit['normal'][2]) < .6 and hit['distanceMeters'] < np.linalg.norm(target-eye)-.25:
                kinds = ['opaqueBlocked']; counts['opaqueBlocked'] += 1
            else:
                kinds = []
            for kind in kinds:
                key = (kind, parent)
                if key in bins or sum(x['kind'] == kind for x in selected) >= 2:
                    continue
                bins.add(key)
                selected.append(dict(kind=kind, originalNavTriangle=tid, nativeNavParent=parent,
                                     nativeNavFeet=feet.tolist(), target=target.tolist(), parentBoundaryMarginMeters=float(margin),
                                     sourceHit=hit, floorRayHit=floor_hit, horizontalRayHit=horizontal_hit,
                                     bodyProbes=body, nearSourceSupport=near, allSourceSupportAlternatives=associations))
        searches.append(dict(agent=name, originalEye=eye.tolist(), query=q.tolist(), counts=counts, selected=len(selected)))
        print(name, counts, 'selected', len(selected), flush=True)
        for i, control in enumerate(selected):
            tid = control['originalNavTriangle']
            receiver = Receiver(nav_tris[tid, :, :2], plane_of(nav_tris[tid]))
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
            shape = shapely.union_all([shapely.Polygon(x['polygon']) for x in shadows])
            target = np.array(control['target'])
            projected = bool(shapely.covers(shape, shapely.Point(target[:2])))
            ray = dict(target=target.tolist(), sourceHit=control['sourceHit'], projectedOpaqueBlocked=projected,
                       differsFromAlphaAwareSource=projected != (control['sourceHit'] is not None))
            fixture_id = f'{name.lower()}-{i:02d}-{control["kind"]}-nav{tid}'
            np.savez_compressed(out/f'{fixture_id}.npz', sourceTriangles=xyz, sourceFaceIds=ids, faceMasks=masks,
                                observer=eye, receiverFootprint=receiver.footprint, receiverPlane=receiver.floor_plane,
                                shadowTrianglesRelativeXY=mesh)
            records.append(dict(id=fixture_id, agent=name, originalEye=eye.tolist(), query=q.tolist(), control=control,
                                rays=[ray], nativeNavVertices=nav_tris[tid].tolist(), maskedFallbackFaces=ids[~opaque].tolist(),
                                contactFallback=pending, sourceCandidates=len(ids), generatedShadowPolygons=len(shadows),
                                pythonProjectionMilliseconds=cost, fixtureBytes=(out/f'{fixture_id}.npz').stat().st_size))
            print(f'{fixture_id}: {len(ids)} faces, differs={ray["differsFromAlphaAwareSource"]}', flush=True)
    report = dict(scope=__doc__, completePackSha256=sha(pack), compositionGateSha256=sha(gate_path),
                  originalNativeXYZSha256=sha(raw_path), originalNavigationSha256=sha(nav_path),
                  sceneSha256=sha(scene_path), supportSha256=sha(support_path), groundSha256=sha(ground_path),
                  scriptSha256=sha(Path(__file__)), projectionSha256=sha(Path(__file__).with_name('finite_receiver_shadows.py')),
                  search=searches, records=records,
                  limitations=['Target feet use literal original Recast Z, not source-refined nav or an implicitly chosen support layer.',
                               'At least one source surface must be within15cm of native nav Z; every overlapping source candidate remains recorded.',
                               'Body checks are five vertical rays from feet+20cm to standing eye, not a recovered pawn capsule sweep.',
                               'Receiver triangles are native nav planes. Only frozen targets have the full margin/association/body gate; their whole footprint is not certified.',
                               'Steep first-hit faces are geometric controls, not object-role classification. Source masks/contact cases remain explicit.',
                               'This is source-backed offline navigation evidence, not live gameplay verification.'])
    (out/'report.json').write_text(json.dumps(report, indent=2)+'\n')


if __name__ == '__main__':
    main()

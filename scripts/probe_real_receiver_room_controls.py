"""Find conditional standing-target controls in frozen Split cones.

Each candidate is an actual retained source-support triangle centroid. No
overlapping height layer is selected implicitly, and no source face is removed.
This is an offline geometry comparison, not a gameplay or reachable-floor claim.
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


def in_cone(xy, query):
    delta = np.asarray(xy) - query[:2]
    distance = np.linalg.norm(delta, axis=-1)
    dot = delta @ (query[3:5] / np.linalg.norm(query[3:5]))
    return (distance >= .5) & (distance <= query[5]) & (dot >= distance * np.cos(query[6] / 2))


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
    meta_path = r/'source-floor-support-all-walkable-v1/split.floor-support.json'
    meta = json.loads(meta_path.read_bytes())
    support_path = meta_path.parent/meta['dataFile']
    assert sha(support_path) == meta['dataSha256']
    with np.load(support_path) as data:
        triangles = data['vertices'][data['triangles']]
        source_ids = data['sourceFaces']
    centroids = triangles.mean(1)
    normals = np.cross(triangles[:, 1]-triangles[:, 0], triangles[:, 2]-triangles[:, 0])
    usable = (source_ids >= 0) & (np.abs(normals[:, 2]) > 1e-12)
    support_indices = np.flatnonzero(usable)
    support_shapes = shapely.polygons(triangles[support_indices, :, :2])
    tree = shapely.STRtree(support_shapes)
    model = NativeReferenceModel(pack, r/'native-tactical-rays-build/Release/tactical_reference_cast.dll')
    output, search_summaries = [], []
    for agent_id, name in [(4, 'Clove'), (6, 'Iso'), (7, 'Viper')]:
        query = np.asarray(queries[agent_id])
        eye = query[:3].copy()
        eye[2] += ground.heights(query[None, :2])[0]
        ids = np.flatnonzero(usable & in_cone(centroids[:, :2], query))
        # Search every centroid, ordered nearest first. A per-layer spatial
        # bin only limits duplicate selected controls, never source geometry.
        ids = ids[np.argsort(np.linalg.norm(centroids[ids, :2]-eye[:2], axis=1), kind='stable')]
        counts = {'opaque-blocked': 0, 'masked-blocked': 0, 'clear': 0,
                  'head-clear-floor-wall-blocked': 0, 'head-clear-horizontal-wall-blocked': 0}
        selected, bins = [], set()
        begin = time.perf_counter()
        for sid in ids:
            target = centroids[sid].copy(); target[2] += 1.75
            hit = model.cast(eye, target)
            floor_hit = horizontal_hit = None
            if hit is None:
                counts['clear'] += 1
                floor_hit = model.cast(eye, centroids[sid])
                horizontal_hit = model.cast(eye, np.r_[target[:2], eye[2]])
                # A floor-hit close to the target or on terrain is not a
                # finite wall-height control. Keep those out of this category.
                floor_wall = floor_hit is not None and not floor_hit['masked'] and abs(floor_hit['normal'][2]) < .6 and floor_hit['distanceMeters'] < np.linalg.norm(centroids[sid]-eye)-.25
                horizontal_wall = horizontal_hit is not None and not horizontal_hit['masked'] and abs(horizontal_hit['normal'][2]) < .6 and horizontal_hit['distanceMeters'] < np.linalg.norm(target[:2]-eye[:2])-.25
                kinds = []
                if floor_wall:
                    kinds.append('head-clear-floor-wall-blocked')
                if horizontal_wall:
                    kinds.append('head-clear-horizontal-wall-blocked')
                for kind in kinds:
                    counts[kind] += 1
            else:
                kinds = ['masked-blocked' if hit['masked'] else 'opaque-blocked']
                counts[kinds[0]] += 1
            for kind in kinds:
                if kind == 'masked-blocked':
                    continue
                if kind == 'opaque-blocked' and (abs(hit['normal'][2]) >= .6 or hit['distanceMeters'] > np.linalg.norm(target-eye)-.25):
                    # Avoid a target head barely inside a surface being the
                    # only blocked-wall control. Search counts stay unchanged.
                    continue
                key = (kind, *np.floor(target / 2).astype(int))
                if key in bins or sum(x['kind'] == kind for x in selected) >= 2:
                    continue
                bins.add(key)
                selected.append(dict(kind=kind, supportId=int(sid), target=target.tolist(), sourceHit=hit,
                                     floorTarget=centroids[sid].tolist(), floorRayHit=floor_hit,
                                     horizontalTarget=[*target[:2], float(eye[2])], horizontalRayHit=horizontal_hit))
            # Preserve broad search counts through at least the first 3000
            # centroids, then stop only once every useful class was found.
            if sum(counts[k] for k in ['clear', 'opaque-blocked', 'masked-blocked']) >= 3000 and all(sum(x['kind'] == k for x in selected) >= 2 for k in ['opaque-blocked', 'head-clear-floor-wall-blocked', 'head-clear-horizontal-wall-blocked']):
                break
        search_summaries.append(dict(agent=name, originalEye=eye.tolist(), query=query.tolist(), availableSourceSupportCentroids=len(ids),
                                     searchedCounts=counts, selectedControls=len(selected), searchMilliseconds=(time.perf_counter()-begin)*1000))
        print(name, counts, 'selected', len(selected), flush=True)
        for index, control in enumerate(selected):
            sid = control['supportId']
            triangle = triangles[sid]
            plane = np.linalg.solve(np.c_[triangle[:, :2], np.ones(3)], triangle[:, 2])
            receiver = Receiver(triangle[:, :2], plane)
            xy = np.array(control['target'][:2])
            overlapping = []
            for other in support_indices[tree.query(shapely.Point(xy), predicate='intersects')]:
                tri = triangles[other]
                coeff = np.linalg.solve(np.c_[tri[:, :2], np.ones(3)], tri[:, 2])
                overlapping.append(dict(supportId=int(other), sourceFace=int(source_ids[other]), floorHeight=float(xy@coeff[:2]+coeff[2]), plane=coeff.tolist()))
            low, high = swept_bounds(eye, receiver)
            faces = query_box(model, low, high)
            xyz = model.arrays['vertices'][model.arrays['faces'][faces]]
            keep = candidates(eye, receiver, xyz.min(1), xyz.max(1))
            faces, xyz = faces[keep], xyz[keep]
            masks = model.arrays['faceMasks'][faces]
            opaque = masks < 0
            start = time.perf_counter()
            shadows, pending = build_shadows(eye, xyz[opaque], [receiver])
            cost = (time.perf_counter()-start)*1000
            for item in pending:
                item['sourceFace'] = int(faces[opaque][item['sourceFace']])
            mesh, output_fallback = renderer_mesh_checked(eye, shadows)
            for item in output_fallback:
                item['sourceFace'] = int(faces[opaque][item['sourceFace']])
            pending.extend(output_fallback)
            polygons = shapely.union_all([shapely.Polygon(x['polygon']) for x in shadows])
            rays = []
            barycentrics = [[1/3, 1/3, 1/3]]
            barycentrics += [[1-u-v, u, v] for u in [.13, .29, .47, .67] for v in [.17, .38, .61] if u+v < .97]
            for bary in barycentrics:
                sample_xy = np.array(bary)@receiver.footprint
                if not in_cone(sample_xy, query):
                    continue
                target = receiver.lift(sample_xy)
                hit = model.cast(eye, target)
                blocked = bool(shapely.covers(polygons, shapely.Point(sample_xy)))
                rays.append(dict(target=target.tolist(), sourceHit=hit, projectedOpaqueBlocked=blocked,
                                 differsFromAlphaAwareSource=blocked != (hit is not None)))
            fixture_id = f'{name.lower()}-{index:02d}-{control["kind"]}-support{sid}'
            np.savez_compressed(out/f'{fixture_id}.npz', sourceTriangles=xyz, sourceFaceIds=faces, faceMasks=masks,
                                observer=eye, receiverFootprint=receiver.footprint, receiverPlane=plane,
                                shadowTrianglesRelativeXY=mesh)
            row = dict(id=fixture_id, agent=name, control=control, query=query.tolist(), originalEye=eye.tolist(),
                       targetSupportSourceFace=int(source_ids[sid]), receiverPlane=plane.tolist(),
                       overlappingSourceSupportCandidates=overlapping, targetLayerIsConditional=True,
                       sourceCandidates=len(faces), maskedFallbackFaces=faces[~opaque].tolist(), contactFallback=pending,
                       generatedShadowPolygons=len(shadows), pythonProjectionMilliseconds=cost, rays=rays,
                       inputBytes=int(xyz.nbytes+masks.nbytes+triangle.nbytes+plane.nbytes), fixtureBytes=(out/f'{fixture_id}.npz').stat().st_size)
            output.append(row)
            print(f'{fixture_id}: {len(faces)} faces, {len(rays)} rays, {sum(x["differsFromAlphaAwareSource"] for x in rays)} differences', flush=True)
            (out/'progress.json').write_text(json.dumps(dict(search=search_summaries, records=output), indent=2)+'\n')
    report = dict(scope=__doc__, completePackSha256=sha(pack), compositionGateSha256=sha(gate_path),
                  sceneManifestSha256=sha(scene_path), supportSha256=sha(support_path), groundSha256=sha(ground_path),
                  sourceSha256={name: sha(Path(__file__).with_name(name)) for name in ['probe_real_receiver_room_controls.py', 'finite_receiver_shadows.py', 'finite_shadow_broadphase.py']},
                  search=search_summaries, records=output,
                  limitations=['Every target layer is conditional; source support admission does not establish reachable feet positions.',
                               'All reported rays are inside the frozen actual source FOV and range; receiver footprints themselves can extend outside it.',
                               'Opaque projection does not implement masked or coplanar contact fallback. Differences involving those remain unresolved.',
                               'The wall label is a geometric steep-face heuristic, not source-object role certification; selected blocked targets lie at least25cm beyond their first hit.',
                               'The source scene preserves the existing control domain, not omitted pre-control source objects.',
                               'Python projection timings are diagnostics, not native or frame-time measurements.'])
    (out/'report.json').write_text(json.dumps(report, indent=2)+'\n')


if __name__ == '__main__':
    main()

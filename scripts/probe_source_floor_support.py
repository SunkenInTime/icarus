"""Diagnostic ground following using real source floor faces beyond nav inset.

No production assets are changed. Experimental admission combines source ground
classification, nearby navigation, and audited effect/prop exclusions. Source
membership still needs review. Navigation can identify a continuing ramp layer
while a source floor preserves upper/lower separation beyond inset nav edges.
Unsupported gaps retain the last floor height.
"""
import argparse
import gzip
import hashlib
import json
import re
from pathlib import Path
import numpy as np
import shapely
from scipy.sparse import coo_matrix
from scipy.sparse.csgraph import connected_components
from audit_tactical_target_rays import ReferenceModel
from source_floor_piece_cast import cast_floor_piece


class SourceSupport:
    def __init__(self, revision, name, source, geometry_seeded=False, nav_support=False, coarse_bridges=False, buffered_support=False, seam_extension=0., all_walkable=False):
        row = next(row for row in json.loads((revision.parent / 'completeness/combined-manifest-release-inputs-v2.json').read_text()) if row['map'] == name)
        world = Path(row['combinedWorldFolder'])
        metadata = json.loads((world / 'geometry.json').read_text())
        objects = metadata['objects']
        starts = np.array([o['firstFace'] for o in objects])
        original = np.load(revision / 'full-height-input-v1' / name / 'source-correspondence.npz')['sourceFaces']
        object_ids = np.searchsorted(starts, original, side='right') - 1
        floor_objects = np.array([bool(re.search(r'floor|stair|ramp|platform', o['path'], re.I)) for o in objects])
        points = source.arrays['vertices'][source.arrays['faces']]
        normal = np.cross(points[:, 1] - points[:, 0], points[:, 2] - points[:, 0])
        length = np.linalg.norm(normal, axis=1)
        upward = (normal[:, 2] > .6 * length) & (length > 1e-10)
        audited_excluded = np.zeros(len(points), dtype=bool)
        if buffered_support:
            from ground_floor_policy import ground_policy_mask
            raw = np.load(world / 'geometry.npz')
            effective_signs = np.ones(len(raw['faces']))
            source_enabled = np.ones(len(raw['faces']), dtype=bool)
            if metadata.get('groundSupport') or metadata.get('groundFacing'):
                from world_visibility_ray_reference import load_ground_facing, load_ground_support, eligible_ground_faces
                floor_report = json.loads((world / 'floor-mesh.json').read_text())
                signs, facing_info = load_ground_facing(world, metadata, floor_report, metadata['geometrySha256'], len(raw['faces']),
                                                       source_arrays=(raw['points'], raw['faces'], raw['material_indices']))
                support, support_info = load_ground_support(world, metadata, floor_report, metadata['geometrySha256'], len(raw['faces']), facing_info)
                excluded_faces = facing_info.get('excludedSourceFaces', [])
                eligible = eligible_ground_faces(raw['points'], raw['faces'], raw['material_indices'], metadata['materials'], signs, excluded_faces, support)
                allowed = np.zeros(len(raw['faces']), dtype=bool); allowed[eligible] = True
                source_enabled[len(signs):] = False
                if support is None:
                    effective_signs[:len(signs)] = signs
                else:
                    authored = np.flatnonzero(support['_authoredMask'])
                    effective_signs[authored] = signs[authored]
                    source_enabled[np.flatnonzero(support['_excludedMask'])] = False
                source_enabled[np.array(excluded_faces, dtype=int)] = False
                ground_proof = dict(facing=facing_info, support=support_info)
            else:
                allowed, ground_proof, _ = ground_policy_mask(world, metadata, raw, revision.parent / f'nav/baked/{name}_source_xyz.json')
            upward = allowed[original]
            for exclusion_directory in ['floor-support-audited-exclusions-v2', 'floor-support-snowman-exclusions-v1']:
                exclusion_path = revision / exclusion_directory / f'{name}.json'
                if not exclusion_path.exists():
                    continue
                exclusions = json.loads(exclusion_path.read_text())
                if exclusions['sourceGeometrySha256'] != metadata['geometrySha256'] or exclusions['fullHeightSourcePackSha256'] != hashlib.sha256((revision / 'full-height-input-v1' / name / f'{name}.height.bin.gz').read_bytes()).hexdigest():
                    raise ValueError('Audited support exclusions identify another source')
                for evidence in exclusions['evidence']:
                    if hashlib.sha256(Path(evidence['path']).read_bytes()).hexdigest() != evidence['sha256']:
                        raise ValueError('Audited support exclusion evidence changed')
                for record in exclusions['rows']:
                    if record['supportDecision'] != 'exclude-from-standing-support':
                        continue
                    full_ids = np.array(record['fullPackFaceIds'], dtype=int)
                    np.testing.assert_array_equal(original[full_ids], record['originalSourceFaceIds'])
                    audited_excluded[full_ids] = True
            upward &= ~audited_excluded
        ids = np.flatnonzero(upward if geometry_seeded else floor_objects[object_ids] & upward)
        if geometry_seeded:
            nav = json.loads(gzip.decompress((revision / 'baseline-world' / f'{name}_navigation.json.gz').read_bytes()))
            entry = json.loads((revision / 'baseline-world/height_catalog.json').read_text())['maps'][name]
            ui = entry['uiTransform']; detail = nav['floorMesh']
            vertices = np.array(detail['vertices'], dtype=float).reshape(-1, 3)
            uv = vertices[:, :2] / detail['coordinateScale']
            vertices[:, 0] = (uv[:, 1] - ui['YScalarToAdd']) / (100 * ui['YMultiplier'])
            vertices[:, 1] = -(uv[:, 0] - ui['XScalarToAdd']) / (100 * ui['XMultiplier'])
            vertices[:, 2] /= 100
            faces = np.array(detail['triangles']).reshape(-1, 4)
            main = json.loads(gzip.decompress((revision / 'global-ground-v1' / f'{name}.tactical-ground.json.gz').read_bytes()))['mainComponent']
            valid = np.array(nav['walkable'])[faces[:, 0]] & (all_walkable | (np.array(nav['components'])[faces[:, 0]] == main))
            floor_triangles = vertices[faces[valid, 1:]]
            detailed_triangle_count = len(floor_triangles)
            floor_shapes = shapely.polygons(floor_triangles[:, :, :2]); tree = shapely.STRtree(floor_shapes)
            floor_planes = np.linalg.solve(np.concatenate([floor_triangles[:, :, :2], np.ones((len(floor_triangles), 3, 1))], axis=2), floor_triangles[:, :, 2, None])[:, :, 0]
            candidate = points[ids]
            samples = np.concatenate([candidate, candidate.mean(1)[:, None]], axis=1).reshape(-1, 3)
            sample_ids, floor_ids = tree.query(shapely.points(samples[:, :2]), predicate='intersects')
            expected = np.sum(samples[sample_ids, :2] * floor_planes[floor_ids, :2], axis=1) + floor_planes[floor_ids, 2]
            seeds = np.unique(sample_ids[abs(samples[sample_ids, 2] - expected) <= .3] // 4)
            # Graph growth never traverses wall faces. Proximity seeds still
            # require provenance review: a low prop/effect can sit near a floor.
            _, vertex_ids = np.unique(np.rint(candidate.reshape(-1, 3) * 1000).astype(np.int64), axis=0, return_inverse=True)
            vertex_ids = vertex_ids.reshape(-1, 3)
            edges = np.sort(np.concatenate([vertex_ids[:, [0, 1]], vertex_ids[:, [1, 2]], vertex_ids[:, [2, 0]]]), axis=1)
            _, edge_ids = np.unique(edges, axis=0, return_inverse=True)
            owners = np.tile(np.arange(len(ids)), 3); order = np.argsort(edge_ids, kind='stable')
            adjacent = edge_ids[order[1:]] == edge_ids[order[:-1]]
            a, b = owners[order[:-1][adjacent]], owners[order[1:][adjacent]]
            graph = coo_matrix((np.ones(len(a)), (a, b)), shape=(len(ids), len(ids))).tocsr()
            _, labels = connected_components(graph, directed=False)
            keep = np.isin(labels, np.unique(labels[seeds]))
            print('source floor support', name, 'upward faces', len(ids), 'nav-backed seeds', len(seeds), 'retained', int(keep.sum()), flush=True)
            ids = ids[keep]
            if coarse_bridges:
                coarse = np.array(nav['vertices'], dtype=float).reshape(-1, 3)
                uv = coarse[:, :2] / nav['coordinateScale']
                coarse[:, 0] = (uv[:, 1] - ui['YScalarToAdd']) / (100 * ui['YMultiplier'])
                coarse[:, 1] = -(uv[:, 0] - ui['XScalarToAdd']) / (100 * ui['XMultiplier'])
                coarse[:, 2] = np.array(nav['refinedFloorHeightsCm']) / 100
                rebuilt = []
                for parent, ring in enumerate(nav['polygons']):
                    if not nav['walkable'][parent] or (not all_walkable and nav['components'][parent] != main):
                        continue
                    polygon = shapely.Polygon(coarse[ring, :2])
                    lookup = {tuple(coarse[i, :2]): i for i in ring}
                    pieces = shapely.get_parts(shapely.constrained_delaunay_triangles(polygon))
                    if abs(sum(piece.area for piece in pieces) - polygon.area) > 1e-8:
                        raise ValueError('Parent floor triangulation changes its footprint')
                    for piece in pieces:
                        rebuilt.append([lookup[tuple(xy)] for xy in np.array(piece.exterior.coords)[:3]])
                floor_triangles = np.concatenate([floor_triangles, coarse[np.array(rebuilt)]])
                if buffered_support:
                    bridge = coarse[np.array(rebuilt)]
                    bridge_planes = np.linalg.solve(np.concatenate([bridge[:, :, :2], np.ones((len(bridge), 3, 1))], axis=2), bridge[:, :, 2, None])[:, :, 0]
                    buffered = shapely.buffer(shapely.polygons(bridge[:, :, :2]), .65)
                    bridge_tree = shapely.STRtree(buffered)
                    solid_materials = np.array([m['category'] in ('opaque', 'unresolved') for m in metadata['materials']])
                    candidate_ids = np.flatnonzero((normal[:, 2] * effective_signs[original] > .001 * length) & (length > 1e-10) &
                                                   solid_materials[raw['material_indices'][original]] & source_enabled[original] & ~audited_excluded)
                    candidates = points[candidate_ids]
                    samples, bridge_ids = bridge_tree.query(shapely.points(candidates.mean(1)[:, :2]), predicate='intersects')
                    predicted = np.einsum('ni,nji->nj', bridge_planes[bridge_ids, :2], candidates[samples, :, :2]) + bridge_planes[bridge_ids, 2, None]
                    errors = np.max(abs(predicted - candidates[samples, :, 2]), axis=1)
                    added = candidate_ids[np.unique(samples[errors <= .35])]
                    ids = np.union1d(ids, added)
                    ids = ids[~audited_excluded[ids]]
                    print('buffered source support', 'added', len(added), 'retained', len(ids), 'excluded', int(audited_excluded.sum()), flush=True)
        self.source_ids = ids
        self.objects = [objects[object_ids[i]]['path'] for i in ids]
        self.points = points[ids]
        self.navigation_indices = np.array([], dtype=int)
        self.detailed_navigation_indices = np.array([], dtype=int)
        if nav_support:
            if not geometry_seeded:
                raise ValueError('Navigation bridges require main-floor source seeding')
            self.navigation_indices = len(self.points) + np.arange(len(floor_triangles))
            self.detailed_navigation_indices = self.navigation_indices[:detailed_triangle_count]
            self.points = np.concatenate([self.points, floor_triangles])
            self.source_ids = np.r_[self.source_ids, -1 - np.arange(len(floor_triangles))]
            self.objects += ['Main navigation detailed floor support'] * len(floor_triangles)
        self.planes = np.linalg.solve(np.concatenate([self.points[:, :, :2], np.ones((len(self.points), 3, 1))], axis=2), self.points[:, :, 2, None])[:, :, 0]
        self.polygons = shapely.polygons(self.points[:, :, :2])
        self.original_polygons = self.polygons.copy()
        extension = np.zeros(len(self.points))
        if seam_extension:
            normals = np.cross(self.points[:, 1] - self.points[:, 0], self.points[:, 2] - self.points[:, 0])
            eligible = (self.source_ids >= 0) & (normals[:, 2] > .65 * np.linalg.norm(normals, axis=1))
            extension[eligible] = seam_extension
            self.polygons[eligible] = shapely.buffer(self.polygons[eligible], seam_extension)
        self.tree = shapely.STRtree(self.polygons)
        if geometry_seeded:
            output = revision / ('source-floor-support-all-walkable-v1' if all_walkable else 'source-floor-support-union-v6' if buffered_support else 'source-floor-support-union-v3' if coarse_bridges else 'source-floor-support-union-v1' if nav_support else 'source-floor-support-geometric-v1')
            output.mkdir(exist_ok=True)
            used, faces = np.unique(self.points.reshape(-1, 3), axis=0, return_inverse=True)
            target = output / f'{name}.floor-support.npz'
            np.savez_compressed(target, vertices=used, triangles=faces.reshape(-1, 3), sourceFaces=self.source_ids, extensionMeters=extension,
                                navigationIndices=self.navigation_indices, detailedNavigationIndices=self.detailed_navigation_indices)
            (output / f'{name}.floor-support.json').write_text(json.dumps(dict(
                version=1, coordinateSpace='native-meters', map=name, dataFile=target.name,
                fullHeightSourcePackSha256=hashlib.sha256((revision / 'full-height-input-v1' / name / f'{name}.height.bin.gz').read_bytes()).hexdigest(),
                dataSha256=hashlib.sha256(target.read_bytes()).hexdigest(), triangles=len(self.points), vertices=len(used), bytes=target.stat().st_size,
                navigationBridgeTriangles=len(floor_triangles) if nav_support else 0,
                mainNavigationComponent=int(main),
                observerScope=('All actual walkable navigation parents retained as distinct floor layers. A correctly selected standing origin is required; automatic origin-layer choice is not certified.' if all_walkable else
                               'Main-navigation standing ground only. Disconnected raised props and explicit eye-height overrides are not certified by this support mesh.'),
                sourceSeamExtensionMeters=seam_extension,
                policy=('Sealed source ground-facing/material eligibility, 1 mm welded component growth from source vertex/centroid within 0.3 m of detailed main nav, plus locally nav-backed faces within a 0.65 m parent footprint buffer and 0.35 m all-vertex plane residual. Hash-bound audited exclusions are applied after both admissions. Proximity may still admit unaudited props; these tolerances are not certified ground-height errors.' if buffered_support else
                        'Upward source faces connected through 1 mm welded edges to faces with a vertex/centroid within 0.3 m of detailed main nav. Proximity may admit props/effects; source membership requires review.'),
                auditedExcludedFaces=int(audited_excluded.sum()),
                status='diagnostic-support-mesh-policy-not-certified'), indent=2) + '\n')

    def cast(self, source, origin, direction, distance, allow_floor_transitions=False, navigation_guided=False, constant_standing_height=False, maximum_step_height=None, lock_after_gap=False, terrain_source_faces=(), raised_source_faces=(), entry_reference=True):
        origin = np.array(origin, dtype=float)
        direction = np.array(direction, dtype=float); direction /= np.linalg.norm(direction)
        vector = direction * distance
        line = shapely.LineString([origin[:2], origin[:2] + vector])
        candidates = self.tree.query(line, predicate='intersects')
        events = [0., 1.]
        intervals = []
        original_intervals = {}
        original_polygons = getattr(self, 'original_polygons', self.polygons)
        for cell in candidates:
            xy = shapely.get_coordinates(line.intersection(self.polygons[cell]))
            if not len(xy):
                continue
            t = np.clip((xy - origin[:2]) @ vector / (distance * distance), 0, 1)
            lo, hi = float(t.min()), float(t.max())
            if hi - lo < 1e-11:
                continue
            events.extend((lo, hi)); intervals.append((lo, hi, int(cell)))
            original_xy = shapely.get_coordinates(line.intersection(original_polygons[cell]))
            if len(original_xy):
                original_t = np.clip((original_xy - origin[:2]) @ vector / (distance * distance), 0, 1)
                original_lo, original_hi = float(original_t.min()), float(original_t.max())
                if original_hi - original_lo >= 1e-11:
                    original_intervals[int(cell)] = (original_lo, original_hi)
                    events.extend((original_lo, original_hi))
        events = np.unique(np.round(events, 13))
        intervals = np.array(intervals).reshape(-1, 3)
        previous_floor = origin[2] - 1.75
        terrain_source_faces = frozenset(terrain_source_faces)
        raised_source_faces = frozenset(raised_source_faces)
        raised_origin = False
        relative_eye = 1.75
        pieces = []
        detached, ever_supported, unsupported_distance = False, False, 0.
        for lo, hi in zip(events, events[1:]):
            if hi <= lo:
                continue
            xy = origin[:2] + np.array([lo, hi])[:, None] * vector
            mid = (lo + hi) / 2
            cells = intervals[(intervals[:, 0] <= mid) & (intervals[:, 1] >= mid), 2].astype(int)
            selected, jump = None, 0.
            heights = np.array([xy @ self.planes[cell, :2] + self.planes[cell, 2] for cell in cells]).reshape(-1, 2)
            if raised_source_faces and lo != 0:
                eligible = np.array([
                    int(self.source_ids[cell]) < 0 or
                    (int(self.source_ids[cell]) in raised_source_faces and
                     abs(heights[i, 0] - previous_floor) <= 1e-5)
                    if raised_origin else int(self.source_ids[cell]) not in raised_source_faces
                    for i, cell in enumerate(cells)], dtype=bool)
                cells, heights = cells[eligible], heights[eligible]
            if len(cells):
                original = np.array([original_intervals.get(int(cell), (1., 0.))[0] <= mid <=
                                     original_intervals.get(int(cell), (1., 0.))[1] for cell in cells])
                step = .35 if maximum_step_height is None else maximum_step_height
                original_source = original & (self.source_ids[cells] >= 0) & (abs(heights[:, 0] - previous_floor) <= step + 1e-6)
                if original_source.any():
                    # Extension repairs missing source coverage. It cannot
                    # replace a compatible, physically present source floor.
                    keep = original | (self.source_ids[cells] < 0)
                    cells, heights = cells[keep], heights[keep]
            nav_reference = None
            if len(cells) and not detached:
                errors = abs(heights[:, 0] - previous_floor)
                close = np.flatnonzero(errors <= .35)
                if navigation_guided:
                    nav = np.flatnonzero(self.source_ids[cells] < 0)
                    if len(nav):
                        # Navigation identifies which physical layer continues
                        # here. A rendered base under a solid ramp is not a
                        # second walkable layer merely because its face exists.
                        nav_pick = int(nav[np.argmin(errors[nav])])
                        continuous_source = close[self.source_ids[cells[close]] >= 0]
                        # Radius-inset navigation may end before the source
                        # floor edge. Another layer's remaining nav must not
                        # pull a continuing upper/lower source branch into it.
                        hint = heights[nav_pick]
                        midpoint_errors = abs(heights[:, 0] - hint[0]) if entry_reference else abs(heights.mean(axis=1) - hint.mean())
                        source_step = .35 if maximum_step_height is None else maximum_step_height
                        real = np.flatnonzero((self.source_ids[cells] >= 0) & (midpoint_errors <= .35) &
                                              (errors <= source_step + 1e-6))
                        if len(real):
                            # Coarse nav can interpolate over physical treads.
                            # The source tread, not that interpolated hint,
                            # determines whether the step fits native climb.
                            nav_reference = hint
                            best = midpoint_errors[real].min()
                            close = real[midpoint_errors[real] <= best + 1e-5]
                            if entry_reference and len(close) > 1:
                                # At a ramp foot both base and ramp have the
                                # same height. The local source tangent which
                                # matches the continuing nav plane wins; no
                                # future support edge participates in this tie.
                                slope_errors = np.linalg.norm(self.planes[cells[close], :2] - self.planes[cells[nav_pick], :2], axis=1)
                                close = close[slope_errors <= slope_errors.min() + 1e-8]
                        else:
                            # Navigation is a layer hint. Its interpolated
                            # plane cannot supply a missing physical tread.
                            close = continuous_source
                if terrain_source_faces and lo != 0:
                    # Only explicitly audited terrain may replace a buried
                    # source base. Prop tops remain valid origin support,
                    # without raising a ray travelling along the ground.
                    step = .35 if maximum_step_height is None else maximum_step_height
                    terrain = np.array([i for i, cell in enumerate(cells)
                                        if int(self.source_ids[cell]) in terrain_source_faces
                                        and errors[i] <= step + 1e-6], dtype=int)
                    if len(terrain):
                        highest = heights[terrain, 0].max()
                        close = terrain[heights[terrain, 0] >= highest - 1e-5]
                close = close[self.source_ids[cells[close]] >= 0]
                if not len(close) and allow_floor_transitions and lo != 0:
                    close = np.flatnonzero(self.source_ids[cells] >= 0)
                if maximum_step_height is not None:
                    # Flatten continuous slopes and native-sized steps. A
                    # ledge or an air gap must not teleport the tactical eye
                    # onto a distant floor merely because it is the only one.
                    close = close[errors[close] <= maximum_step_height + 1e-6]
                if len(close):
                    # Prefer the connected face first, then the least-changing
                    # continuation for coincident source floor boundaries.
                    best_error = errors[close].min()
                    tied = close[errors[close] <= best_error + 1e-5]
                    pick = int(tied[np.argmin(abs(heights[tied, 1] - heights[tied, 0]))])
                    selected = int(cells[pick]); ground = heights[pick]
                    if lo == 0:
                        raised_origin = int(self.source_ids[selected]) in raised_source_faces
                    jump = abs(float(ground[0] - previous_floor))
                    if lo == 0 and not constant_standing_height:
                        relative_eye = float(origin[2] - ground[0])
                else:
                    ground = np.full(2, previous_floor)
            else:
                ground = np.full(2, previous_floor)
            if selected is not None:
                ever_supported = True
                unsupported_distance = 0.
            elif ever_supported:
                unsupported_distance += (hi - lo) * distance
                if lock_after_gap and unsupported_distance > 1e-4:
                    # A real gap/ledge ends ground following for this ray.
                    # A distant floor approaching the old height must not
                    # reattach on one side of a numerical climb threshold.
                    # Sub-0.1 mm seams tolerate source-coordinate roundoff.
                    detached = True
            z = ground + relative_eye
            source_plane = self.planes[selected] if selected is not None else np.array([0., 0., ground[0]])
            hit = cast_floor_piece(source, origin[:2], direction, distance, source_plane,
                                   lo * distance, hi * distance, relative_eye)
            pieces.append(dict(start=lo * distance, end=hi * distance, sourceFace=None if selected is None else int(self.source_ids[selected]),
                               object=None if selected is None else self.objects[selected], ground=ground.tolist(), joinErrorMeters=jump,
                               navigationReference=None if nav_reference is None else nav_reference.tolist(),
                               supportState='detached' if detached else 'supported' if selected is not None else 'gap',
                               candidateCount=len(cells), closestCandidateHeightError=None if not len(cells) else float(np.min(abs(heights[:, 0] - previous_floor)))))
            previous_floor = float(ground[1])
            if hit:
                return dict(hit=hit, distanceMeters=float((np.array(hit['point'][:2]) - origin[:2]) @ direction), pieces=pieces)
        return dict(hit=None, distanceMeters=distance, pieces=pieces)


def probe(revision, name, geometry_seeded=False, allow_floor_transitions=False, nav_support=False, coarse_bridges=False, buffered_support=False, seam_extension=0., navigation_guided=False, constant_standing_height=False, all_walkable=False, export_only=False):
    source = ReferenceModel(revision / 'full-height-input-v1' / name / f'{name}.height.bin.gz')
    support = SourceSupport(revision, name, source, geometry_seeded, nav_support, coarse_bridges, buffered_support, seam_extension, all_walkable)
    if export_only:
        return
    data = json.loads((revision / 'gallery-all-map-lower-provisional-v1' / f'{name}-lost-source-directions.json').read_text())
    results = []
    for case in data['cases']:
        samples = []
        for ray in case['lostDirections']:
            result = support.cast(source, case['query'][:3], ray['direction'][:2], case['query'][5], allow_floor_transitions,
                                  navigation_guided, constant_standing_height)
            result.update(directionIndex=ray['directionIndex'], beforeDistanceMeters=ray['beforeDistanceMeters'], previousDistanceMeters=ray['afterDistanceMeters'])
            samples.append(result)
        results.append(dict(id=case['id'], query=case['query'], samples=samples))
        print(case['id'], 'rays', len(samples), 'gained>1m', sum(s['distanceMeters'] - s['previousDistanceMeters'] > 1 for s in samples),
              'lost>1m', sum(s['previousDistanceMeters'] - s['distanceMeters'] > 1 for s in samples), flush=True)
    output = revision / ('source-floor-support-nav-guided-v1' if navigation_guided else 'source-floor-support-union-transitions-v6' if buffered_support else 'source-floor-support-union-transitions-v3' if coarse_bridges and allow_floor_transitions else 'source-floor-support-union-v3' if coarse_bridges else 'source-floor-support-union-transitions-v1' if nav_support and allow_floor_transitions else 'source-floor-support-union-v1' if nav_support else 'source-floor-support-transitions-v1' if allow_floor_transitions else 'source-floor-support-geometric-v1' if geometry_seeded else 'source-floor-support-v1')
    output.mkdir(exist_ok=True)
    (output / f'{name}.json').write_text(json.dumps(dict(map=name, scope=__doc__, sourceFloorTriangles=len(support.points), cases=results), indent=2) + '\n')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('revision', type=Path)
    parser.add_argument('map')
    parser.add_argument('--geometry-seeded', action='store_true')
    parser.add_argument('--allow-floor-transitions', action='store_true')
    parser.add_argument('--nav-support', action='store_true')
    parser.add_argument('--coarse-bridges', action='store_true')
    parser.add_argument('--buffered-support', action='store_true')
    parser.add_argument('--seam-extension', type=float, default=0.)
    parser.add_argument('--navigation-guided', action='store_true')
    parser.add_argument('--constant-standing-height', action='store_true')
    parser.add_argument('--all-walkable', action='store_true')
    parser.add_argument('--export-only', action='store_true')
    args = parser.parse_args()
    probe(args.revision, args.map, args.geometry_seeded, args.allow_floor_transitions, args.nav_support, args.coarse_bridges, args.buffered_support, args.seam_extension,
          args.navigation_guided, args.constant_standing_height, args.all_walkable, args.export_only)

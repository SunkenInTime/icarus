"""Correct Icebox Tube levels and nonblocking map symbols from reviewed sources."""
import copy
import gzip
import json
from pathlib import Path

import numpy as np
import shapely

from audit_svg_source_height_associations import ROOT, REV
from build_split_svg_ground import triangulated_parts
from compile_reviewed_svg_height_map import polygon, rings


def main():
    output = REV / 'icebox-mid-elevation-audit-v2'
    output.mkdir(exist_ok=True)
    original = REV / 'icebox-svg-height-decisions-v1/icebox-svg-height-decisions-v1.json'
    decisions = json.loads(original.read_text())
    raw = np.load(ROOT / 'supplemented-v2/world/icebox/geometry.npz')
    objects = json.loads((ROOT / 'supplemented-v2/world/icebox/geometry.json').read_text())['objects']
    matrix = np.array(json.loads((ROOT / 'tactical-alignment-sides-v1/icebox.json').read_text())['nativeToAttackSvg'])
    inverse = np.linalg.inv(matrix[:, :2])
    def native(xy):
        return (np.asarray(xy) - matrix[:, 2]) @ inverse.T
    def triangles(oid):
        o = objects[oid]
        return raw['points'][raw['faces'][o['firstFace']:o['firstFace'] + o['faceCount']]].astype(float)

    # Preserve the original ground outside these two actual floor meshes.
    base = json.loads(gzip.decompress((REV / 'global-ground-v1/icebox.tactical-ground.json.gz').read_bytes()))
    vertices = np.array(base['vertices']).reshape(-1, 3)
    faces = np.array(base['triangles']).reshape(-1, 3)
    ground_domain = shapely.union_all(shapely.polygons(vertices[faces, :2]))
    patches = []
    covered = shapely.Polygon()
    for oid in (4759, 4760):
        t = triangles(oid)
        n = np.cross(t[:, 1] - t[:, 0], t[:, 2] - t[:, 0])
        valid = (abs(n[:, 2]) > .65 * np.linalg.norm(n, axis=1)) & (abs(n[:, 2]) > 1e-9)
        # Highest coincident floor face wins over the slab underside, within
        # these named floor objects only. Roofs and props are never candidates.
        for tri in sorted(t[valid], key=lambda q: -q[:, 2].mean()):
            domain = shapely.Polygon(tri[:, :2]).intersection(ground_domain).difference(covered)
            plane = np.linalg.solve(np.c_[tri[:, :2], np.ones(3)], tri[:, 2])
            for piece in triangulated_parts(domain):
                xy = np.array(piece.exterior.coords[:-1])
                patches.append(np.c_[xy, np.c_[xy, np.ones(3)] @ plane])
            covered = covered.union(domain)
    result = list(patches)
    for tri in vertices[faces]:
        plane = np.linalg.solve(np.c_[tri[:, :2], np.ones(3)], tri[:, 2])
        for piece in triangulated_parts(shapely.Polygon(tri[:, :2]).difference(covered)):
            xy = np.array(piece.exterior.coords[:-1])
            result.append(np.c_[xy, np.c_[xy, np.ones(3)] @ plane])
    result = np.array(result)
    assert ground_domain.symmetric_difference(shapely.union_all(shapely.polygons(result[:, :, :2]))).area < 1e-6
    ground = dict(version=1, map='icebox', coordinateSpace='native-meters',
                  vertices=result.reshape(-1).tolist(), triangles=list(range(result.shape[0] * 3)),
                  sourceObjects=[4759, 4760], reviewStatus='reviewed')
    ground_path = output / 'icebox-ground.json.gz'
    ground_path.write_bytes(gzip.compress(json.dumps(ground, separators=(',', ':')).encode(), mtime=0))
    decisions.update(groundModel=str(ground_path), groundReviewStatus='reviewed')

    rows = decisions['walls']
    rows = list(rows.values()) if isinstance(rows, dict) else rows
    by_id = {w['wallId']: w for w in rows}
    changed = []
    for w in rows:
        if w['wallId'].startswith('p24-stroke-') or w['wallId'] in ('p18-stroke-0', 'p18-stroke-1'):
            w.pop('parts', None)
            w.update(mode='connected-ground', bandsAboveFloor=[], reviewStatus='reviewed',
                     reason='A Site zipline symbol confirmed by Dara, or cross-hall Tube ramp/floor marking. Painted map annotation, not an opaque wall.',
                     gameplayReview='Dara zipline annotation; named continuous Tube floor meshes 4759/4760 cross both ramp markings.')
            changed.append(w['wallId'])

    # The old wall-bottom lips are not independent standing platforms.
    removed = {'p7-stroke-11-source-4758-top', 'p7-stroke-12-source-4757-top'}
    decisions['supports'] = [s for s in decisions['supports'] if s['id'] not in removed]

    # Profile the ramp housing vertically. Each partition retains the exact
    # painted SVG ink. A band's bounds enclose the source over one SVG unit;
    # the reviewed flat body remains a solid structural assembly.
    source = np.concatenate([triangles(i) for i in (4753, 4754, 4755, 4757, 4758, 4761)])
    source[:, :, :2] = source[:, :, :2] @ matrix[:, :2].T + matrix[:, 2]
    profiles = {}
    for side, limits in [('left', (179, 181)), ('right', (190, 192))]:
        bands = []
        for y0 in np.arange(225, 263, 1.):
            zs = []
            # Intersect every triangle with the complete XY slab, including
            # vertical faces, using convex clipping in XYZ.
            selected = ((source[:, :, 0].max(1) >= limits[0]) &
                        (source[:, :, 0].min(1) <= limits[1]) &
                        (source[:, :, 1].max(1) >= y0) &
                        (source[:, :, 1].min(1) <= y0 + 1))
            for tri in source[selected]:
                q = list(tri)
                for axis, bound, greater in [(0, limits[0], True), (0, limits[1], False), (1, y0, True), (1, y0 + 1, False)]:
                    prev = q[-1] if q else None
                    clipped = []
                    for cur in q:
                        cin = cur[axis] >= bound if greater else cur[axis] <= bound
                        pin = prev[axis] >= bound if greater else prev[axis] <= bound
                        if cin != pin:
                            clipped.append(prev + (cur - prev) * ((bound - prev[axis]) / (cur[axis] - prev[axis])))
                        if cin:
                            clipped.append(cur)
                        prev = cur
                    q = clipped
                zs.extend(float(p[2]) for p in q)
            if zs:
                bands.append(dict(y0=float(y0), low=min(zs), high=max(zs)))
        profiles[side] = bands
    body_roof = float(triangles(4755)[:, :, 2].max())
    for wid in ['p7-stroke-11', 'p7-stroke-12', 'p7-stroke-13', 'p7-stroke-14', 'p7-stroke-15', 'p7-stroke-16', 'p14-stroke-9']:
        w = by_id[wid]
        parts = []
        for b in profiles['left' if wid == 'p7-stroke-11' else 'right']:
            parts.append(dict(id=f'ramp-{int(b["y0"])}', clipBox=[178, b['y0'], 195, b['y0'] + 1],
                              mode='source-height', floorElevationMeters=0., bandsAboveFloor=[[b['low'], b['high']]],
                              reviewStatus='reviewed', selectedSourceObjects=[4753, 4754, 4761],
                              reason='Measured source ramp housing vertical extent; SVG footprint unchanged.'))
        parts.append(dict(id='tube-structure', remainder=True, mode='source-height', floorElevationMeters=0.,
                          bandsAboveFloor=[[0, body_roof]], reviewStatus='reviewed', selectedSourceObjects=[4755],
                          reason='Remaining Tube body and returns stay solid up to the measured main housing roof.'))
        w.update(parts=parts)
        changed.append(wid)

    # The lower path beneath the ramp is a distinct selectable surface. The
    # corridor footprint is authored; the source floor supplies its elevation.
    under = shapely.box(180.248, 225.25, 191.918, 241.459)
    decisions['supports'].append(dict(id='mid-under-tube', label='Under Tube', reviewStatus='reviewed',
        rings=rings(under), fillRule='evenodd', surfaceElevationMeters=1., floorElevationMeters=1.,
        heightAboveFloorMeters=0., sourceObjects=[4697], reason='Lower Mid floor beneath the Tube ramp, separate from the ramp walking surface.'))
    roof = triangles(4755)
    normal = np.cross(roof[:, 1] - roof[:, 0], roof[:, 2] - roof[:, 0])
    top = (abs(normal[:, 2]) > .99 * np.linalg.norm(normal, axis=1)) & (abs(roof[:, :, 2] - body_roof).max(1) < .02)
    top_xy = roof[top, :, :2] @ matrix[:, :2].T + matrix[:, 2]
    roof_domain = shapely.union_all(shapely.polygons(top_xy)).intersection(shapely.box(180.248, 171.691, 191.918, 221.99))
    assert roof_domain.area > 20
    decisions['supports'].append(dict(id='mid-tube-roof', label='Tube roof', reviewStatus='reviewed',
        rings=[r for p in shapely.get_parts(roof_domain) if p.geom_type == 'Polygon' for r in rings(p)],
        fillRule='evenodd', surfaceElevationMeters=body_roof, floorElevationMeters=1.,
        heightAboveFloorMeters=body_roof - 1., sourceObjects=[4755],
        reason='Measured broad horizontal roof surface on the Tube housing, explicitly selected rather than default ground.'))
    decisions['walls'] = rows
    decisions['lineage'] = dict(previous=str(original), correction='Dara Icebox elevation and zipline review')
    path = output / 'icebox-mid-decisions.json'
    path.write_text(json.dumps(decisions, separators=(',', ':')))
    (output / 'evidence.json').write_text(json.dumps(dict(changedWalls=changed, removedFalseSupports=sorted(removed),
        primaryFloorSources=[4759, 4760], floorPatchAreaMetersSquared=covered.area, rampVerticalProfiles=profiles,
        limitations=['Ramp housing bands enclose each one-SVG-unit section. This conservatively retains wall material within that section.']), indent=2))
    print(path)


if __name__ == '__main__':
    main()

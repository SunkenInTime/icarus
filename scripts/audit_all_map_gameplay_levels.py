"""Compare bundled standing levels with original walkable navigation and art.

This reports candidates. Neither a nearby mesh nor a passing cone test grants
gameplay eligibility. Original navigation supplies independent floor evidence;
the art supplies precise local height, and SVG ink retains wall XY authority.
"""
import argparse
from collections import Counter
import gzip
import hashlib
import json
from pathlib import Path
import numpy as np
import shapely
from audit_svg_source_height_associations import ROOT, REV, EXCLUDED
from compile_reviewed_svg_height_map import polygon

MAPS = 'abyss ascent bind breeze corrode fracture haven icebox lotus pearl split summit sunset'.split()
OUT = REV / 'all-map-gameplay-v5'


def read(path):
    data = path.read_bytes()
    return json.loads(gzip.decompress(data) if path.suffix == '.gz' else data)


def planes(triangles):
    return np.linalg.solve(np.concatenate([triangles[:, :, :2], np.ones((len(triangles), 3, 1))], axis=2), triangles[:, :, 2, None])[:, :, 0]


def sample_domain(domain, subdivisions=5):
    result = [domain.representative_point()]
    x0, y0, x1, y1 = domain.bounds
    for x in np.linspace(x0, x1, subdivisions + 2)[1:-1]:
        for y in np.linspace(y0, y1, subdivisions + 2)[1:-1]:
            p = shapely.Point(x, y)
            if domain.contains(p):
                result.append(p)
    return result


def audit(name):
    output = OUT / name
    output.mkdir(parents=True, exist_ok=True)
    asset = Path(f'assets/maps/{name}_svg_height_attack.json.gz')
    model = read(asset)
    for side in ['attack', 'defense']:
        source = Path(f'assets/maps/{name}_svg_height_{side}.json.gz')
        target = output / f'before-{side}.json.gz'
        if not target.exists():
            target.write_bytes(source.read_bytes())
    matrix = np.array(read(ROOT / f'tactical-alignment-sides-v1/{name}.json')['nativeToAttackSvg'])
    inverse = np.linalg.inv(matrix[:, :2])
    scale = float(np.linalg.norm(matrix[0, :2]))
    def svg(xy):
        return np.asarray(xy) @ matrix[:, :2].T + matrix[:, 2]
    def native(xy):
        return (np.asarray(xy) - matrix[:, 2]) @ inverse.T

    source_nav_path = ROOT / f'nav/baked/{name}_source_xyz.json'
    source_nav = read(source_nav_path)
    nav_path = ROOT / f'nav/baked/{name}_navigation.json'
    assert source_nav['navigationSha256'] == hashlib.sha256(nav_path.read_bytes()).hexdigest()
    nav = read(nav_path)
    vertices = np.array(source_nav['vertices'], dtype=float).reshape(-1, 3) / 100
    vertices[:, 1] *= -1
    raw_triangles = np.array(source_nav['triangles'], dtype=int).reshape(-1, 4)
    keep = np.array(nav['walkable'])[raw_triangles[:, 0]]
    nav_parents = raw_triangles[keep, 0]
    nav_triangles = vertices[raw_triangles[keep, 1:]]
    nav_shapes = shapely.polygons(nav_triangles[:, :, :2])
    valid = shapely.area(nav_shapes) > 1e-10
    nav_shapes, nav_triangles, nav_parents = nav_shapes[valid], nav_triangles[valid], nav_parents[valid]
    nav_tree, nav_planes = shapely.STRtree(nav_shapes), planes(nav_triangles)

    receiver = shapely.union_all([polygon(r) for r in model['receiver']])
    ground_vertices = np.array(model['ground']['vertices']).reshape(-1, 3)
    ground = ground_vertices[np.array(model['ground']['triangles']).reshape(-1, 3)]
    ground_tree, ground_planes = shapely.STRtree(shapely.polygons(ground[:, :, :2])), planes(ground)
    support_shapes = [polygon(s) for s in model['supports']]
    support_tree = shapely.STRtree(support_shapes)
    def ground_at(xy):
        ids = ground_tree.query(shapely.Point(xy), predicate='intersects')
        if not len(ids):
            return None
        p = ground_planes[ids.min()]
        return float(p[:2] @ xy + p[2])

    # Source face identity survives filtering; later decisions must identify
    # these local faces rather than the highest face elsewhere on their object.
    source_path = ROOT / f'supplemented-v2/world/{name}/geometry.npz'
    archive = np.load(source_path)
    points, faces = archive['points'], archive['faces']
    metadata = read(source_path.with_suffix('.json'))
    objects = metadata['objects']
    source_triangles, source_ids, owners = [], [], []
    for oid, obj in enumerate(objects):
        if not obj['faceCount'] or any(s in obj['path'].lower() for s in EXCLUDED):
            continue
        ids = np.arange(obj['firstFace'], obj['firstFace'] + obj['faceCount'])
        tri = points[faces[ids]].astype(float)
        normal = np.cross(tri[:, 1] - tri[:, 0], tri[:, 2] - tri[:, 0])
        length = np.linalg.norm(normal, axis=1)
        good = (abs(normal[:, 2]) > .65 * length) & (length > 1e-8)
        if good.any():
            source_triangles.append(tri[good])
            source_ids.extend(ids[good].tolist())
            owners.extend([oid] * int(good.sum()))
    source_triangles = np.concatenate(source_triangles)
    source_ids, owners = np.array(source_ids), np.array(owners)
    source_shapes = shapely.polygons(source_triangles[:, :, :2])
    source_tree, source_planes = shapely.STRtree(source_shapes), planes(source_triangles)
    print(json.dumps(dict(map=name,stage='loaded',sourceFloorFaces=len(source_ids),walkableNavTriangles=len(nav_triangles))), flush=True)

    samples, missing, uncertain_source = [], [], []
    barycentric = np.array([[1/3, 1/3, 1/3], [.6, .2, .2], [.2, .6, .2], [.2, .2, .6]])
    for ti, triangle in enumerate(nav_triangles):
        for sample in barycentric @ triangle:
            xy, nz = sample[:2], float(sample[2])
            pos = svg(xy)
            if not receiver.covers(shapely.Point(pos)):
                continue
            ids = source_tree.query(shapely.Point(xy), predicate='intersects')
            z = source_planes[ids, :2] @ xy + source_planes[ids, 2]
            near = np.flatnonzero((z >= nz - .6) & (z <= nz + .2))
            row = dict(svg=pos.tolist(), nativeXY=xy.tolist(), nativeNavZ=nz,
                navTriangle=ti, navParent=int(nav_parents[ti]), navComponent=int(nav['components'][nav_parents[ti]]))
            if not len(near):
                uncertain_source.append(row)
                continue
            order = near[np.argsort(abs(z[near] - nz))]
            best = int(ids[order[0]])
            elevation = float(z[order[0]])
            candidates = sorted(set(int(owners[i]) for i in ids[near]))
            ground_z = ground_at(pos)
            matches = support_tree.query(shapely.Point(pos), predicate='intersects')
            matching = [model['supports'][i]['id'] for i in matches if abs(model['supports'][i]['surfaceElevationMeters'] - elevation) < .15]
            row.update(sourceZ=elevation, sourceObject=int(owners[best]), sourcePath=objects[owners[best]]['path'],
                sourceFace=int(source_ids[best]), sourceCandidateObjects=candidates,
                groundZ=ground_z, matchingSupports=matching)
            samples.append(row)
            if not matching and (ground_z is None or abs(elevation - ground_z) > .3):
                row['sourceMinusGroundMeters'] = None if ground_z is None else elevation - ground_z
                missing.append(row)

    support_rows = []
    for support, domain in zip(model['supports'], support_shapes):
        rows = []
        for p in sample_domain(domain):
            xy = native([p.x, p.y])
            ids = nav_tree.query(shapely.Point(xy).buffer(.5), predicate='intersects')
            nav_close = []
            for ni in ids:
                nearest = shapely.ops.nearest_points(shapely.Point(xy), nav_shapes[ni])[1] if not nav_shapes[ni].covers(shapely.Point(xy)) else shapely.Point(xy)
                nxy = np.array(nearest.coords)[0]
                nz = float(nav_planes[ni, :2] @ nxy + nav_planes[ni, 2])
                if abs(nz - support['surfaceElevationMeters']) <= .6:
                    nav_close.append(dict(parent=int(nav_parents[ni]), navZ=nz, distanceMeters=float(p.distance(shapely.Point(svg(nxy))) / scale)))
            source_hits = source_tree.query(shapely.Point(xy), predicate='intersects')
            sz = source_planes[source_hits, :2] @ xy + source_planes[source_hits, 2]
            matched = source_hits[abs(sz - support['surfaceElevationMeters']) < .15]
            rows.append(dict(svg=[p.x, p.y], navMatches=nav_close,
                matchingSourceObjects=sorted(set(int(owners[i]) for i in matched))))
        support_rows.append(dict(id=support['id'],label=support.get('label'),surfaceElevationMeters=support['surfaceElevationMeters'],
            automaticStandingAllowed=support.get('automaticStandingAllowed',False), samples=len(rows),
            navBackedSamples=sum(bool(r['navMatches']) for r in rows), sourceBackedSamples=sum(bool(r['matchingSourceObjects']) for r in rows), rows=rows))

    groups = []
    for oid in sorted({r['sourceObject'] for r in missing}):
        rows = [r for r in missing if r['sourceObject'] == oid]
        groups.append(dict(object=oid,path=objects[oid]['path'],samples=len(rows),
            zRange=[min(r['sourceZ'] for r in rows),max(r['sourceZ'] for r in rows)],
            groundDifferenceRange=[min((r['sourceMinusGroundMeters'] for r in rows if r['sourceMinusGroundMeters'] is not None),default=None),max((r['sourceMinusGroundMeters'] for r in rows if r['sourceMinusGroundMeters'] is not None),default=None)],
            svgBounds=shapely.MultiPoint([r['svg'] for r in rows]).bounds))
    report = dict(map=name,assetSha256=hashlib.sha256(asset.read_bytes()).hexdigest(),
        originalNavigationSha256=hashlib.sha256(source_nav_path.read_bytes()).hexdigest(),
        sourceGeometrySha256=hashlib.sha256(source_path.read_bytes()).hexdigest(),
        samples=samples,missingLevels=missing,missingLevelGroups=groups,sourceUnresolved=uncertain_source,supports=support_rows)
    (output/'level-audit.json').write_text(json.dumps(report,separators=(',',':')))
    summary = dict(map=name,navSamples=len(samples),sourceUnresolved=len(uncertain_source),missingLevelSamples=len(missing),
        missingLevelGroups=len(groups),supports=len(support_rows),
        fullyNavBackedSupports=sum(s['samples']==s['navBackedSamples'] for s in support_rows),
        partlyNavBackedSupports=sum(0<s['navBackedSamples']<s['samples'] for s in support_rows),
        supportsWithoutNav=sum(s['navBackedSamples']==0 for s in support_rows),
        groups=sorted(groups,key=lambda r:-r['samples']))
    (output/'summary.json').write_text(json.dumps(summary,indent=2))
    print(json.dumps({k:v for k,v in summary.items() if k!='groups'}),flush=True)
    return summary


if __name__ == '__main__':
    import shapely.ops
    p=argparse.ArgumentParser();p.add_argument('maps',nargs='*',default=MAPS);args=p.parse_args()
    result=[audit(name) for name in args.maps]
    OUT.mkdir(exist_ok=True)
    (OUT/'level-audit-summary.json').write_text(json.dumps(result,indent=2))

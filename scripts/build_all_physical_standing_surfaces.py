"""Enumerate physical standing tops independently of navigation and object names."""
import argparse
from collections import Counter, defaultdict
import gzip
import hashlib
import json
from pathlib import Path
import re
import numpy as np
import shapely
from shapely.affinity import affine_transform
from audit_all_map_gameplay_levels import MAPS, ROOT, OUT, read, planes
from build_all_map_gameplay_supports import standing_obstacles, plane_region
from compile_reviewed_svg_height_map import polygon, rings
from gameplay_standing_volumes import StandingVolumes, vertical_contacts, walkable_slope_angle, inside_closed_mesh

OUTPUT = ROOT / 'tactical-visibility-revision/all-map-standing-surfaces-v9'
CONFIG = ROOT / 'camera/config/ShooterGame/Config/DefaultEngine.ini'
PLAYER = ROOT / 'camera/player-properties/properties/ShooterGame/Content/Characters/_Core/BasePawn.json'


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def affine(matrix):
    return [*matrix[0, :2], *matrix[1, :2], *matrix[:, 2]]


def transformed_plane(plane, matrix):
    linear = plane[:2] @ np.linalg.inv(matrix[:, :2])
    return np.r_[linear, plane[2] - linear @ matrix[:, 2]]


def standing_face_domain(triangles,indices,plane):
    contact=.42*plane[:2]/np.sqrt(1+float(plane[:2]@plane[:2]))
    faces=shapely.union_all(shapely.polygons(triangles[indices,:,:2]))
    return affine_transform(faces,[1.,0.,0.,1.,-contact[0],-contact[1]])


def top_planes(triangles, equations, max_slope_degrees):
    normals = np.cross(triangles[:, 1]-triangles[:, 0], triangles[:, 2]-triangles[:, 0])
    length = np.linalg.norm(normals, axis=1)
    if equations is not None:
        upward = equations[:, 2]
    else:
        # Open complex floors can have either exported winding. Their player
        # clearance is checked against the complete body after enumeration.
        upward = np.divide(abs(normals[:, 2]), length, out=np.zeros(len(length)), where=length>1e-10)
    keep = (length > 1e-10) & (upward > 1e-8) & (upward >= np.cos(np.deg2rad(max_slope_degrees))-1e-9)
    groups = defaultdict(list)
    for index in np.flatnonzero(keep):
        t = triangles[index]
        if equations is None and inside_closed_mesh(triangles,t.mean(axis=0)+[0.,0.,1e-4]):
            continue
        plane = np.linalg.solve(np.c_[t[:, :2], np.ones(3)], t[:, 2])
        groups[tuple(np.round(plane, 7))].append(int(index))
    return groups


def freeze(name):
    directory = OUTPUT/name
    directory.mkdir(parents=True, exist_ok=True)
    for side in ['attack', 'defense']:
        before = directory/f'before-{side}.json.gz'
        asset = Path(f'assets/maps/{name}_svg_height_{side}.json.gz')
        if not before.exists():
            before.write_bytes(asset.read_bytes())
    return directory


def selected_ground_domains(triangles):
    """Match the runtime's first triangle at overlapping ground levels."""
    shapes = np.asarray([shapely.Polygon(t[:, :2]) for t in triangles], dtype=object)
    tree = shapely.STRtree(shapes)
    return [shape.difference(shapely.union_all([
        shapes[j] for j in tree.query(shape, predicate='intersects') if j < i
    ])) for i, shape in enumerate(shapes)]


def build(name, supplement=False):
    directory = freeze(name)
    models = {s:read(directory/f'{"candidate" if supplement else "before"}-{s}.json.gz') for s in ['attack', 'defense']}
    previous = read(directory/'physical-top-build.json') if supplement else None
    alignment_path = ROOT/f'tactical-alignment-sides-v1/{name}.json'
    alignment = read(alignment_path)
    matrices = {s:np.asarray(alignment[f'nativeTo{s.title()}Svg']) for s in models}
    attack = matrices['attack']
    inverse = np.linalg.inv(attack[:, :2])
    inverse_matrix = np.c_[inverse, -inverse @ attack[:, 2]]
    receivers = {s:shapely.union_all([polygon(r) for r in m['receiver']]) for s,m in models.items()}
    native_receiver = affine_transform(receivers['attack'], affine(inverse_matrix))
    volumes = StandingVolumes(name)
    if volumes.unresolved:
        raise ValueError((name, volumes.unresolved))
    # The shipped navigation configuration supplies a conservative standing
    # slope bound. Local collision overrides can tighten or widen that bound.
    slope_values = re.findall(r'^AgentMaxSlope=([0-9.]+)', CONFIG.read_text(), re.M)
    assert len(slope_values) == 1
    default_slope = float(slope_values[0])
    sample_old = read(OUT/name/'standing-clearance.json')['samples']
    navigation_by_body = defaultdict(list)
    for r in sample_old:
        if r['standingCollision']:
            navigation_by_body[r['standingCollision']].append(r)
    # Coverage uses only a matching local elevation, so an existing upper
    # floor never consumes a separate usable lower level.
    old_ground = np.asarray(models['attack']['ground']['vertices']).reshape(-1,3)
    old_tri = old_ground[np.asarray(models['attack']['ground']['triangles']).reshape(-1,3)]
    covered_shapes = selected_ground_domains(old_tri)
    covered_planes = list(planes(old_tri))
    shadowed = [shapely.Polygon(t[:, :2]).difference(selected)
                for t, selected in zip(old_tri, covered_shapes)]
    shadowed_tree = shapely.STRtree(shadowed)
    ground_planes = np.asarray(covered_planes)
    for s in models['attack']['supports']:
        if s.get('automaticStandingAllowed'):
            covered_shapes.append(polygon(s))
            covered_planes.append(np.asarray(s.get('surfacePlane') or [0.,0.,s['surfaceElevationMeters']]))
    covered_shapes = np.asarray(covered_shapes, dtype=object)
    covered_planes = np.asarray(covered_planes)
    covered_tree = shapely.STRtree(covered_shapes)
    wall_shapes = {s:np.asarray([polygon(w) for w in m['walls']],dtype=object) for s,m in models.items()}
    wall_trees = {s:shapely.STRtree(shapes) for s,shapes in wall_shapes.items()}
    records, additions = [], []
    for index, row in enumerate(volumes.rows):
        triangles = volumes.triangles[index]
        bounds = row['bounds']
        if not native_receiver.intersects(shapely.box(*bounds[0][:2], *bounds[1][:2])):
            records.append(dict(collision=row['id'],status='outside-displayed-map'))
            continue
        if row['kill'] or row['unwalkable']:
            records.append(dict(collision=row['id'],status='player-kill-volume' if row['kill'] else 'explicit-unwalkable'))
            continue
        if row.get('collisionDefaultsUnknown'):
            records.append(dict(collision=row['id'],status='unresolved-collision-defaults'))
            continue
        slope = walkable_slope_angle(row,default_slope)
        groups = top_planes(triangles, volumes.equations[index], slope)
        if not groups:
            records.append(dict(collision=row['id'],status='no-standing-facing-plane'))
        for key, indices in groups.items():
            plane = np.asarray(key)
            # The rounded feet touch uphill from the capsule axis on a slope.
            # Translate the actual finite faces to the corresponding origins.
            faces=shapely.union_all(shapely.polygons(triangles[indices,:,:2]))
            domain = faces.union(standing_face_domain(triangles,indices,plane)).intersection(native_receiver)
            record = dict(collision=row['id'],nativeSurfacePlane=plane.tolist(),sourceCollisionFaces=indices,
                status='outside-displayed-map',navigationCorroboratingSamples=len(navigation_by_body[row['id']]))
            records.append(record)
            if domain.is_empty or domain.area < 1e-10:
                continue
            svg_plane = transformed_plane(plane, attack)
            svg = affine_transform(domain, affine(attack))
            if supplement:
                svg = shapely.union_all([plane_region(svg.intersection(shadowed[i]),
                    svg_plane-ground_planes[i], -.015, .015)
                    for i in shadowed_tree.query(svg, predicate='intersects')])
                if svg.is_empty or svg.area < 1e-10:
                    record['status'] = 'no-shadowed-ground-coverage'
                    continue
                domain = affine_transform(svg, affine(inverse_matrix))
            covered = []
            for i in covered_tree.query(svg, predicate='intersects'):
                covered.append(plane_region(svg.intersection(covered_shapes[i]), svg_plane-covered_planes[i], -.015, .015))
            if covered:
                svg = svg.difference(shapely.union_all(covered))
                domain = affine_transform(svg, affine(inverse_matrix))
            if domain.is_empty or domain.area < 1e-10:
                record['status'] = 'already-covered-at-this-elevation'
                continue
            coordinates = shapely.get_coordinates(domain)
            heights = coordinates @ plane[:2]+plane[2]
            low, high = float(heights.min()), float(heights.max())
            record.update(candidateAreaSquareMeters=float(domain.area),elevationRange=[low,high])
            lift = .42*(np.sqrt(1+float(plane[:2]@plane[:2]))-1)
            ignore = {index} if volumes.equations[index] is not None else set()
            obstacles = standing_obstacles(volumes,domain,low+lift,ignored=ignore,height=1.96+high-low,floor_plane=plane)
            domain = shapely.set_precision(shapely.make_valid(domain),1e-7).difference(
                shapely.set_precision(shapely.make_valid(obstacles),1e-7))
            if domain.is_empty or domain.area < 1e-10:
                record['status'] = 'no-clear-standing-player-domain'
                continue
            side_domains = {}
            for side, matrix in matrices.items():
                side_plane = transformed_plane(plane,matrix)
                svg = affine_transform(domain,affine(matrix)).intersection(receivers[side])
                blocks = []
                for i in wall_trees[side].query(svg,predicate='intersects'):
                    w = models[side]['walls'][i]
                    assert not w['unknownHeight']
                    for lo,hi in w['bands']:
                        floor = w['floorElevationMeters']
                        lower = -np.inf if lo==0 else floor+lo-models[side]['defaultCameraHeightMeters']
                        upper = floor+hi-models[side]['defaultCameraHeightMeters']
                        blocks.append(plane_region(wall_shapes[side][i],side_plane,lower,upper))
                side_domains[side] = svg.difference(shapely.union_all(blocks))
            defense = matrices['defense']
            linear = attack[:,:2] @ np.linalg.inv(defense[:,:2])
            shift = attack[:,2]-linear @ defense[:,2]
            paired = side_domains['attack'].intersection(affine_transform(side_domains['defense'],[*linear[0],*linear[1],*shift]))
            if paired.is_empty or paired.area < 1e-8:
                record['status'] = 'no-domain-outside-active-svg-walls'
                continue
            paired = shapely.union_all([p for p in shapely.get_parts(paired)
                if p.geom_type=='Polygon' and p.area>1e-8])
            if paired.is_empty:
                record['status'] = 'no-domain-outside-active-svg-walls'
                continue
            identifier = f'{name}-physical-top-'+hashlib.sha256((row['id']+str(key)).encode()).hexdigest()[:12]
            record.update(status='added-physical-standing-surface',supportId=identifier,addedAreaSvg=float(paired.area))
            additions.append((identifier,plane,paired,record))
        if index % 100 == 0:
            print(name,index,'/',len(volumes.rows),'bodies,',len(additions),'new surfaces',flush=True)
    for side, model in models.items():
        matrix = matrices[side]
        linear = matrix[:,:2] @ inverse
        shift = matrix[:,2]-linear @ attack[:,2]
        for sid,plane,paired,_ in additions:
            existing = next((s for s in model['supports'] if s['id']==sid), None)
            if supplement:
                original = next((s for s in models['attack']['supports'] if s['id']==sid), None)
                if original is not None:
                    # Attack is encoded first; retain that exact ring order on
                    # the mirrored side as well.
                    paired = polygon(original) if side=='defense' else polygon(original).union(paired)
            svg = paired if side=='attack' else affine_transform(paired,[*linear[0],*linear[1],*shift])
            encoded = [r for p in shapely.get_parts(svg) if p.geom_type=='Polygon' for r in rings(p)]
            if supplement and side=='defense':
                encoded=[(np.asarray(r).reshape(-1,2)@linear.T+shift).reshape(-1).tolist()
                         for r in original['rings']]
            assert encoded
            local = transformed_plane(plane,matrix)
            p = svg.representative_point()
            anchor = float(local[:2]@[p.x,p.y]+local[2])
            support = dict(id=sid,label='Platform',rings=encoded,fillRule='evenodd',floorElevationMeters=0.,
                heightAboveFloorMeters=anchor,surfaceElevationMeters=anchor,automaticStandingAllowed=True)
            if np.linalg.norm(plane[:2]) > 1e-9:
                support['surfacePlane'] = local.tolist()
            if existing is None: model['supports'].append(support)
            else: existing.update(support)
        (directory/f'candidate-{side}.json.gz').write_bytes(gzip.compress(json.dumps(model,separators=(',',':'),allow_nan=False).encode(),mtime=0))
    report = dict(map=name,collisionBodies=len(volumes.rows),newSupports=len(additions),records=records,
        counts=dict(Counter(r['status'] for r in records)),sourceVolumeEvidence=volumes.rows,
        alignmentSha256=sha(alignment_path),configSha256=sha(CONFIG),playerSha256=sha(PLAYER),
        beforeSha256={s:sha(directory/f'before-{s}.json.gz') for s in models},
        candidateSha256={s:sha(directory/f'candidate-{s}.json.gz') for s in models},
        navigationPolicy='Navigation is supplementary evidence. No connectivity, object-role or navigation-presence filter determines standing eligibility.')
    if supplement:
        changed = {r['supportId']:r for r in records if r.get('supportId')}
        retained = [r for r in previous['records'] if r.get('supportId') not in changed]
        report['records'] = retained + list(changed.values())
        report['counts'] = dict(Counter(r['status'] for r in report['records']))
        report['newSupports'] = len(models['attack']['supports'])-len(read(directory/'before-attack.json.gz')['supports'])
        report['groundOverlapSupplement'] = dict(changedSupports=list(changed),records=records)
        if 'contactRefinements' in previous: report['contactRefinements']=previous['contactRefinements']
    (directory/'physical-top-build.json').write_text(json.dumps(report,separators=(',',':')))
    print(json.dumps({k:v for k,v in report.items() if k in ['map','collisionBodies','newSupports','counts']}),flush=True)


if __name__ == '__main__':
    parser=argparse.ArgumentParser()
    parser.add_argument('maps',nargs='*',default=MAPS)
    parser.add_argument('--supplement-shadowed-ground',action='store_true')
    args=parser.parse_args()
    for name in args.maps:
        build(name,args.supplement_shadowed_ground)

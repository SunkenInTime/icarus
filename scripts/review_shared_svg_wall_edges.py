"""Restore named facade heights on painted edges previously assigned to boxes."""
import json
import numpy as np
import shapely
from shapely.affinity import affine_transform

from audit_all_map_gameplay_levels import ROOT, read
from audit_assumed_svg_height_sections import clipped_height_intervals, merge_intervals
from compile_reviewed_svg_height_map import polygon, rings
from svg_review_source import source_world, verified_source_pack


# Bounds follow the exact painted common edge, not the source mesh perimeter.
EDGES = {
    'pearl': [
        ('p16-stroke-1-p16-stroke-1-remainder-0', [78.09348, 160.421, 79.09349, 168.154], 6959),
    ],
    'summit': [
        ('p1-stroke-0-prop-3-0', [88.633, 252.485, 89.633, 260.129], 5676),
        ('p1-stroke-0-prop-2-0', [17.4472, 146.466, 18.4472, 151.62], 6300),
        ('p1-stroke-0-prop-5-0', [314.023, 276.775, 315.023, 284.007], 5480),
        ('p2-stroke-10-prop-0-0', [286.41, 300.648, 286.91, 308.286], 5482),
    ],
}


def apply(name, models, directory, transform):
    if name not in EDGES:
        return []
    from compile_local_svg_wall_profiles import components
    source = source_world(name)
    objects = read(source / 'geometry.json')['objects']
    with np.load(source / 'geometry.npz') as data:
        points, faces = data['points'], data['faces']
    pack = verified_source_pack(name)
    matrix = np.array(read(ROOT / f'tactical-alignment-sides-v1/{name}.json')['nativeToAttackSvg'])
    inverse = np.linalg.inv(matrix[:, :2])
    records = []
    for wid, bounds, oid in EDGES[name]:
        original = next(w for w in models['attack']['walls'] if w['id'] == wid)
        domain = polygon(original).intersection(shapely.box(*bounds))
        obj = objects[oid]
        ids = np.arange(obj['firstFace'], obj['firstFace'] + obj['faceCount'])
        ids = ids[pack['retained'][ids]]
        tangent = inverse @ np.array([0., 1.])
        tangent /= np.linalg.norm(tangent)
        samples = []
        for y in np.linspace(bounds[1]+.1, bounds[3]-.1, 9):
            xy = np.array([(bounds[0]+bounds[2])/2, y])
            native = inverse @ (xy-matrix[:, 2])
            selected, intervals = clipped_height_intervals(points[faces[ids]].astype(float),
                native, tangent, .2, 1., include_flat=True)
            if not len(selected):
                # Authored end caps can extend past a registered source corner.
                # Only measured interior sections supply this facade's height.
                continue
            bands = merge_intervals(intervals)
            samples.append(dict(svg=xy.tolist(), native=native.tolist(),
                faces=ids[selected].tolist(), measuredBands=bands))
        # Use the lowest measured complete facade top along this short common
        # edge. A decorative projection at one station cannot raise the edge.
        if len(samples) < 3:
            raise ValueError((name, wid, 'Insufficient named wall sections'))
        top = min(max(hi for _, hi in s['measuredBands']) for s in samples)
        previous_top = original['floorElevationMeters'] + max(hi for _, hi in original['bands'])
        if top <= previous_top:
            raise ValueError((name, wid, 'Shared facade is not taller than box'))
        for side in ['attack', 'defense']:
            target = domain if side == 'attack' else affine_transform(domain, transform)
            changed = []
            for wall in models[side]['walls']:
                shape = polygon(wall)
                piece = shape.intersection(target)
                if piece.area < 1e-10:
                    changed.append(wall)
                    continue
                for i, part in enumerate(components(shape.difference(target))):
                    changed.append({**wall, 'id': f'{wall["id"]}-shared-rest-{i}', 'rings': rings(part)})
                for i, part in enumerate(components(piece)):
                    changed.append({**wall, 'id': f'{wall["id"]}-shared-facade-{i}',
                        'rings': rings(part), 'floorElevationMeters': 0.,
                        'bands': [[0., top]], 'unknownHeight': False})
            models[side]['walls'] = changed
        records.append(dict(originalWallId=wid, sourceObject=oid, sourcePath=obj['path'],
            domainRings=rings(domain), measuredTopMeters=top, samples=samples,
            evidence='The literal box edge continues the adjacent building facade. '
                     'Local source sections and the eye-height source slice show '
                     'the building body occupying this common edge above the box.'))
    (directory / 'shared-wall-edge-review.json').write_text(json.dumps(dict(
        sourceProof=pack['proof'], records=records), separators=(',', ':')))
    return records

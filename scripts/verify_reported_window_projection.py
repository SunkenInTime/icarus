"""Compare projected wall shadows with independent 3D segment intersections."""
import argparse
import hashlib
import gzip
import json
import sys
import time
from pathlib import Path
import numpy as np
import shapely
from shapely.affinity import scale
sys.path.insert(0, 'scripts')
from compile_reviewed_svg_height_map import polygon

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--side', choices=['attack', 'defense'], required=True)
parser.add_argument('--models', type=Path, required=True)
parser.add_argument('--alignment', type=Path, default=Path('E:/IcarusWorldAudit/2026-09-06/tactical-alignment-sides-v1/haven.json'))
args = parser.parse_args()
side = args.side
model_path = args.models / f'haven-{side}.json.gz'
model = json.loads(gzip.decompress(model_path.read_bytes()))
origin = np.array([198.18, 256.97])
if side == 'defense':
    alignment=json.loads(args.alignment.read_bytes())
    a,b=[np.array(alignment[f'nativeTo{s}Svg']) for s in ['Attack','Defense']]
    native=np.linalg.solve(a[:,:2],origin-a[:,2]);origin=b[:,:2]@native+b[:,2]
eye, target_eye = 3.926739889299151, 4.75
region = polygon(next(s for s in model['supports'] if s['id'] == 'haven-measured-volume-362-0'))
region = region.intersection(shapely.Point(origin).buffer(100, quad_segs=96))
influence = shapely.union_all([region, shapely.Point(origin)]).convex_hull
walls = [(w, polygon(w)) for w in model['walls']]
walls = [(w, shape) for w, shape in walls if shape.intersects(influence)]
start = time.perf_counter()
shadows = []
for wall, shape in walls:
    for lo, hi in wall['bands']:
        bottom = -np.inf if lo == 0 else wall['floorElevationMeters'] + lo
        top = wall['floorElevationMeters'] + hi
        near_t, far_t = sorted([(bottom - eye) / (target_eye - eye), (top - eye) / (target_eye - eye)])
        near_t, far_t = max(0., near_t), min(1., far_t)
        if far_t <= 0 or near_t > far_t:
            continue
        near_scale = 1. / far_t
        far_scale = 1. / near_t if near_t > 0 else max(near_scale, 200. / max(shape.distance(shapely.Point(origin)), 1e-6))
        shadows += [scale(shape, xfact=s, yfact=s, origin=tuple(origin)).intersection(region) for s in [near_scale, far_scale]]
        for ring in wall['rings']:
            xy = np.array(ring).reshape(-1, 2)
            for a, b in zip(xy, np.roll(xy, -1, axis=0)):
                if np.linalg.norm(a - b) < 1e-10:
                    continue
                quad = shapely.Polygon([origin + (a-origin)*near_scale, origin + (b-origin)*near_scale,
                                        origin + (b-origin)*far_scale, origin + (a-origin)*far_scale])
                if quad.area > 1e-12:
                    shadows.append(shapely.make_valid(quad).intersection(region))
visible = region.difference(shapely.union_all(shadows))
print('walls', len(walls), 'area', region.area, 'visible', visible.area, 'seconds', time.perf_counter()-start)

def blocked(target):
    line = shapely.LineString([origin, target])
    for wall, shape in walls:
        overlap = line.intersection(shape)
        if overlap.is_empty:
            continue
        for part in shapely.get_parts(overlap):
            if part.geom_type not in ['LineString', 'Point']:
                raise ValueError(part.geom_type)
            distances = [line.project(shapely.Point(xy), normalized=True) for xy in part.coords]
            z0, z1 = sorted(eye + (target_eye - eye) * np.array([min(distances), max(distances)]))
            for lo, hi in wall['bands']:
                bottom = -np.inf if lo == 0 else wall['floorElevationMeters'] + lo
                top = wall['floorElevationMeters'] + hi
                if z0 <= top and z1 >= bottom:
                    return True
    return False

checks, failures, cases = 0, [], []
for x in np.arange(region.bounds[0], region.bounds[2], .35):
    for y in np.arange(region.bounds[1], region.bounds[3], .35):
        p = shapely.Point(x, y)
        if not region.contains(p) or visible.boundary.distance(p) < .002:
            continue
        expected = not blocked(np.array([x, y]))
        actual = visible.contains(p)
        checks += 1
        cases.append(dict(point=[x, y], visible=expected))
        if expected != actual:
            failures.append([x, y, expected, actual])
print('independent checks', checks, 'failures', len(failures))
(args.models / f'window-projection-proof-{side}.json').write_text(json.dumps(dict(
    modelSha256=hashlib.sha256(model_path.read_bytes()).hexdigest(),
    algorithmSha256=hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
    origin=origin.tolist(), eye=eye, targetEye=target_eye, visible=json.loads(shapely.to_geojson(visible)),
    checks=checks, failures=failures, cases=cases), indent=2))
assert not failures


"""Bake parsed BasePawn Recast tiles into static floor triangles and portals.

No Art roof detection, SVG collision, or proximity-only graph edges. Ground
polygons come from the player's Recast mesh. Internal neighbors are explicit;
external neighbors require opposite tile portals with overlapping spans.
"""
import argparse
import base64
import collections
import hashlib
import json
from pathlib import Path

SCALE = 1_000_000


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def vector(value):
    return (value['X'], value['Y'], value['Z'])


def to_unreal(value):
    return (-value[0], -value[2], value[1])


def bake(paths, ui, name):
    parameters = None
    tiles = {}
    source = []
    for path in sorted(paths):
        document = json.loads(path.read_text(encoding='utf8'))
        for mesh in document['meshes']:
            if not mesh['navigationDataName'].endswith('-BasePawn'):
                continue
            if mesh['version'] >= 28:
                raise ValueError('Tile-local vertex encoding needs explicit decoding')
            parameters = mesh.get('parameters') or parameters
            if mesh['tiles']:
                source.append({'path': str(path), 'sha256': sha(path),
                               'mesh': mesh['navigationDataName']})
            for tile in mesh['tiles']:
                h = tile['Header']
                key = (h['X'], h['Y'], h['Layer'])
                if key in tiles and tiles[key] != tile:
                    raise ValueError(f'Conflicting tiles: {name} {key}')
                tiles[key] = tile
    if not parameters or not tiles:
        raise ValueError(f'Missing BasePawn navigation: {name}')

    def uv(value):
        x, y, z = to_unreal(value)
        return (round((y * ui['XMultiplier'] + ui['XScalarToAdd']) * SCALE),
                round((x * ui['YMultiplier'] + ui['YScalarToAdd']) * SCALE),
                round(z, 3))

    vertices, vertex_ids, polygons, walkable, triangles = [], {}, [], [], []
    world_vertices = []
    records, lookup = [], {}
    area_counts = collections.Counter()
    excluded_links = 0

    def vertex(value):
        encoded = uv(value)
        if encoded not in vertex_ids:
            vertex_ids[encoded] = len(vertices) // 3
            vertices.extend(encoded)
            world_vertices.extend(to_unreal(value))
        return vertex_ids[encoded]

    for key, tile in sorted(tiles.items()):
        for local, poly in enumerate(tile['Polys']):
            area = poly['AreaAndType'] & 63
            if poly['AreaAndType'] >> 6:
                excluded_links += 1
                continue
            if poly['VertCount'] < 3:
                raise ValueError('Degenerate ground polygon')
            values = [vector(tile['Vertices'][i])
                      for i in poly['Verts'][:poly['VertCount']]]
            polygon = len(polygons)
            lookup[key, local] = polygon
            polygons.append([vertex(v) for v in values])
            # Default, obstacle-cost and breakable-door areas are walkable.
            # Crouch, flying, damage/jump and null areas are never inferred walks.
            walkable.append(area in (63, 1, 6))
            area_counts[area] += 1
            records.append((key, local, poly, values))
            detail = tile['DetailMeshes'][local]
            detail_values = values + [vector(v) for v in tile['DetailVertices'][
                detail['VertBase']:detail['VertBase'] + detail['VertCount']]]
            for encoded in tile['DetailTris'][detail['TriBase']:
                                               detail['TriBase'] + detail['TriCount']]:
                a, b, c, _ = base64.b64decode(encoded)
                triangles.extend((polygon, vertex(detail_values[a]),
                                  vertex(detail_values[b]), vertex(detail_values[c])))

    links, seen, external = [], set(), collections.defaultdict(list)

    def link(first, second, a, b):
        if first == second or not walkable[first] or not walkable[second]:
            return
        encoded_a, encoded_b = uv(a)[:2], uv(b)[:2]
        if encoded_a == encoded_b:
            return
        key = (first, second, min(encoded_a, encoded_b), max(encoded_a, encoded_b))
        if key in seen:
            return
        seen.add(key)
        links.extend((first, second, *encoded_a, *encoded_b))

    for polygon, (key, local, poly, values) in enumerate(records):
        for edge, neighbor in enumerate(poly['Neis'][:poly['VertCount']]):
            a, b = values[edge], values[(edge + 1) % len(values)]
            if not neighbor:
                continue
            if neighbor & 0x8000:
                side = neighbor & 0xff
                if side not in (0, 2, 4, 6):
                    raise ValueError(f'Unsupported portal direction {side}')
                axis = 0 if side in (0, 4) else 2
                if abs(a[axis] - b[axis]) > .01:
                    raise ValueError('External portal is not on its tile edge')
                external[(axis, round(a[axis], 2))].append((polygon, side, a, b))
            else:
                target = lookup.get((key, neighbor - 1))
                if target is not None:
                    link(polygon, target, a, b)

    climb = float(parameters['WalkableClimb'])
    for (axis, _), edges in external.items():
        along = 2 if axis == 0 else 0
        for index, (first, side, a, b) in enumerate(edges):
            for second, other_side, c, d in edges[index + 1:]:
                if (side + 4) % 8 != other_side:
                    continue
                lo = max(min(a[along], b[along]), min(c[along], d[along]))
                hi = min(max(a[along], b[along]), max(c[along], d[along]))
                if hi - lo <= .01:
                    continue

                def at(p, q, value):
                    t = (value - p[along]) / (q[along] - p[along])
                    return tuple(p[i] + t * (q[i] - p[i]) for i in range(3))

                aa, bb, cc, dd = at(a, b, lo), at(a, b, hi), at(c, d, lo), at(c, d, hi)
                if max(abs(aa[1] - cc[1]), abs(bb[1] - dd[1])) > climb + .01:
                    continue
                link(first, second, aa, bb)
                link(second, first, cc, dd)

    for first, second, a, b in seen:
        if (second, first, a, b) not in seen:
            raise ValueError(f'Nonreciprocal ground portal: {first} -> {second}')

    adjacency = collections.defaultdict(list)
    for i in range(0, len(links), 6):
        adjacency[links[i]].append(links[i + 1])
    components = [-1] * len(polygons)
    component = 0
    for origin in range(len(polygons)):
        if components[origin] >= 0 or not walkable[origin]:
            continue
        queue = [origin]
        components[origin] = component
        for current in queue:
            for neighbor in adjacency[current]:
                if components[neighbor] < 0:
                    components[neighbor] = component
                    queue.append(neighbor)
        component += 1

    return {
        'schemaVersion': 1, 'map': name, 'coordinateScale': SCALE,
        'source': {'kind': 'BasePawn Recast navigation', 'files': source,
                   'agentRadiusCm': parameters['WalkableRadius'],
                   'agentHeightCm': parameters['WalkableHeight'],
                   'walkableClimbCm': climb,
                   'dynamicStatePolicy': 'Breakable ground areas allowed; no off-mesh state links.',
                   'excludedOffMeshLinks': excluded_links,
                   'groundAreaCounts': dict(area_counts)},
        'vertices': vertices, 'polygons': polygons, 'triangles': triangles,
        'links': links, 'components': components, 'walkable': walkable,
        '_worldVerticesCm': world_vertices,
    }


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--navigation', required=True, type=Path)
    parser.add_argument('--properties', required=True, type=Path)
    parser.add_argument('--manifest', required=True, type=Path)
    parser.add_argument('--output', required=True, type=Path)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    results = []
    for row in json.loads(args.manifest.read_text())['maps']:
        code = row['code']
        paths = [p for p in args.navigation.rglob('*.json')
                 if p.parent.name.lower() == code.lower()]
        ui_path = next(p for p in args.properties.rglob('*_UIData.json')
                       if p.stem.lower() == f'{code}_UIData'.lower())
        ui = next(x['Properties'] for x in json.loads(ui_path.read_text(encoding='utf8'))
                  if 'XMultiplier' in x.get('Properties', {}))
        data = bake(paths, ui, row['map'])
        data['source']['uiDataSha256'] = sha(ui_path)
        world = {'schemaVersion': 1, 'map': row['map'],
                 'coordinates': 'Unreal XYZ centimetres',
                 'vertices': data.pop('_worldVerticesCm'),
                 'triangles': data['triangles'], 'polygons': data['polygons']}
        out = args.output / f"{row['map']}_navigation.json"
        out.write_text(json.dumps(data, separators=(',', ':')), encoding='utf8')
        world['navigationSha256'] = sha(out)
        (args.output / f"{row['map']}_source_xyz.json").write_text(
            json.dumps(world, separators=(',', ':')), encoding='utf8')
        heights = sorted(set(data['vertices'][2::3]))
        summary = {'map': row['map'], 'path': str(out), 'sha256': sha(out),
                   'polygons': len(data['polygons']), 'triangles': len(data['triangles']) // 4,
                   'links': len(data['links']) // 6, 'bytes': out.stat().st_size,
                   'components': dict(collections.Counter(data['components'])),
                   'heightsCm': heights}
        results.append(summary)
        print(row['map'], summary['polygons'], summary['triangles'], summary['links'],
              summary['components'], flush=True)
    (args.output / 'manifest.json').write_text(json.dumps(results, indent=2), encoding='utf8')


if __name__ == '__main__':
    main()

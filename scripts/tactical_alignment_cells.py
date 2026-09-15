"""Split source triangles at registration-warp cells before applying their affine maps."""
import copy
import gzip
import json
import struct

import numpy as np


def cross(a, b):
    return a[0] * b[1] - a[1] * b[0]


def clip_triangle(xy, cell):
    # Rows are barycentric weights in the original 3D triangle.
    polygon = [np.eye(3)[i] for i in range(3)]
    sign = 1 if sum(cross(cell[i], cell[(i + 1) % len(cell)]) for i in range(len(cell))) > 0 else -1
    for edge in range(len(cell)):
        a, b = cell[edge], cell[(edge + 1) % len(cell)]
        output = []
        if not polygon:
            return []
        previous = polygon[-1]
        pd = cross(b - a, previous @ xy - a) * sign
        for current in polygon:
            cd = cross(b - a, current @ xy - a) * sign
            if (cd >= -1e-10) != (pd >= -1e-10):
                fraction = pd / (pd - cd)
                output.append(previous + fraction * (current - previous))
            if cd >= -1e-10:
                output.append(current)
            previous, pd = current, cd
        polygon = output
    return polygon


def split_arrays(arrays, project, inverse_project, warp):
    source_vertices, source_faces = arrays['vertices'], arrays['faces']
    svg_vertices = project(source_vertices[:, :2])
    ids = warp.tri.find_simplex(svg_vertices)
    face_cells = ids[source_faces]
    lo, hi = svg_vertices[source_faces].min(1), svg_vertices[source_faces].max(1)
    active_cells = np.any(np.linalg.norm(warp.delta[warp.tri.simplices], axis=2) > 0, axis=1)
    cells = warp.points[warp.tri.simplices]
    cell_lo, cell_hi = cells.min(1), cells.max(1)
    affected = np.zeros(len(source_faces), dtype=bool)
    # Connected active cells form local patches; bounding a whole patch avoids
    # scanning every source face separately for hundreds of adjacent cells.
    pending = set(np.flatnonzero(active_cells).tolist())
    patch_bounds = []
    while pending:
        seed = pending.pop()
        group, stack = [seed], [seed]
        while stack:
            for neighbor in warp.tri.neighbors[stack.pop()]:
                if int(neighbor) in pending:
                    pending.remove(int(neighbor))
                    group.append(int(neighbor))
                    stack.append(int(neighbor))
        patch_bounds.append((cell_lo[group].min(0), cell_hi[group].max(0)))
    for lower, upper in patch_bounds:
        affected |= np.all(hi >= lower, axis=1) & np.all(lo <= upper, axis=1)
    crossed = affected & ((face_cells[:, 0] != face_cells[:, 1]) | (face_cells[:, 1] != face_cells[:, 2]))
    preserved_ids = np.flatnonzero(~crossed)
    vertices = source_vertices.copy()
    vertices[:, :2] = inverse_project(warp.apply(svg_vertices))
    faces = source_faces[preserved_ids].tolist()
    parents = preserved_ids.tolist()
    masks = []
    uv_list, materials = [], []
    for parent in preserved_ids:
        mask = arrays['faceMasks'][parent]
        masks.append(-1 if mask < 0 else len(uv_list))
        if mask >= 0:
            uv_list.append(arrays['maskedUvs'][mask])
            materials.append(arrays['maskedMaterials'][mask])
    appended_vertices = []
    maximum_affine_error = 0.
    area_error = []
    split_children = []
    for parent in np.flatnonzero(crossed):
        source = source_vertices[source_faces[parent]]
        xy = svg_vertices[source_faces[parent]]
        candidates = np.flatnonzero(np.all(cell_hi >= lo[parent], axis=1) & np.all(cell_lo <= hi[parent], axis=1))
        original_area = np.linalg.norm(np.cross(source[1] - source[0], source[2] - source[0])) / 2
        child_area = 0.
        for cell_id in candidates:
            polygon = clip_triangle(xy, cells[cell_id])
            for corner in range(1, len(polygon) - 1):
                bary = np.array([polygon[0], polygon[corner], polygon[corner + 1]])
                triangle = bary @ source
                # The determinant is the exact area fraction in source barycentric
                # coordinates. Recomputing a cross product in world coordinates
                # loses precision for the thin faces produced by the prior cut.
                area = abs(float(np.linalg.det(bary))) * original_area
                if area < max(original_area * 1e-12, 1e-24):
                    continue
                # Degenerate projected wall faces lying on a cell edge belong
                # to both cells. Assign their centroid to one deterministic cell.
                center = (bary @ xy).mean(0)
                if np.abs(cross(xy[1] - xy[0], xy[2] - xy[0])) < 1e-10:
                    owner = warp.tri.find_simplex(center, tol=1e-9)
                    if owner != cell_id:
                        continue
                warped = triangle.copy()
                warped[:, :2] = inverse_project(warp.apply(bary @ xy))
                first = len(vertices) + len(appended_vertices)
                appended_vertices.extend(warped)
                faces.append([first, first + 1, first + 2])
                parents.append(int(parent))
                split_children.append(len(faces) - 1)
                mask = arrays['faceMasks'][parent]
                masks.append(-1 if mask < 0 else len(uv_list))
                if mask >= 0:
                    uv_list.append(bary @ arrays['maskedUvs'][mask])
                    materials.append(arrays['maskedMaterials'][mask])
                error = np.linalg.norm(project(warped[:, :2]).mean(0) - warp.apply(center))
                maximum_affine_error = max(maximum_affine_error, float(error))
                child_area += area
        area_error.append(abs(child_area - original_area) / max(original_area, 1e-15))
        if area_error[-1] > 1e-6:
            raise ValueError(f'Cell clipping failed at source face {parent}: relative area {area_error[-1]}, source area {original_area}, child area {child_area}, cells {face_cells[parent].tolist()}, XY {xy.tolist()}')
    if area_error and max(area_error) > 1e-6:
        raise ValueError(f'Cell clipping lost or duplicated source area: {max(area_error)}')
    if appended_vertices:
        vertices = np.concatenate((vertices, np.array(appended_vertices)))
    faces = np.array(faces, dtype=np.uint32)
    tri = vertices[faces]
    lower, upper = tri.min(1), tri.max(1)
    centers = (lower + upper) / 2
    order = np.arange(len(faces), dtype=np.uint32)
    bounds, nodes = [], []
    def partition(start, end):
        node = len(nodes)
        nodes.append(None)
        ids = order[start:end]
        minimum, maximum = lower[ids].min(0), upper[ids].max(0)
        bounds.append([*minimum, *maximum])
        if end - start <= 16:
            nodes[node] = [start, end - start, -1, -1]
        else:
            axis = np.argmax(maximum - minimum)
            half = (end - start) // 2
            order[start:end] = ids[np.argpartition(centers[ids, axis], half)]
            left = partition(start, start + half)
            right = partition(start + half, end)
            nodes[node] = [0, 0, left, right]
        return node
    partition(0, len(faces))
    result = {'vertices': vertices, 'faces': faces[order], 'bounds': np.array(bounds, dtype=np.float64),
              'nodes': np.array(nodes, dtype=np.int32), 'faceMasks': np.array(masks, dtype=np.int32)[order],
              'maskedUvs': np.array(uv_list, dtype=np.float64).reshape(-1, 3, 2), 'maskedMaterials': np.array(materials, dtype=np.uint32)}
    return result, np.array(parents, dtype=np.uint32)[order], {
        'splitSourceFaces': int(crossed.sum()), 'candidateFaces': len(faces),
        'addedFaces': len(faces) - len(source_faces), 'addedVertices': len(appended_vertices),
        'maximumChildAffineCentroidErrorSvg': maximum_affine_error,
        'maximumSourceAreaRelativeError': max(area_error, default=0),
        'navigationCellSplitting': 'not yet applied; navigation vertices use same field but polygon/detail interiors remain approximate'}


def encode(header, arrays, original_raw):
    header = copy.deepcopy(header)
    old_header_size = struct.unpack_from('<I', original_raw, 4)[0]
    old_base = (8 + old_header_size + 7) // 8 * 8
    textures = [original_raw[old_base + t['offset']:old_base + t['offset'] + t['width'] * t['height']] for t in header['textures']]
    payload = bytearray()
    header['arrays'] = {}
    for name, data in arrays.items():
        while len(payload) % 8:
            payload.append(0)
        header['arrays'][name] = {'offset': len(payload), 'count': int(data.size), 'shape': list(data.shape), 'dtype': str(data.dtype)}
        payload.extend(data.tobytes())
    for item, texture in zip(header['textures'], textures):
        item['offset'] = len(payload)
        payload.extend(texture)
    header['retainedFaces'], header['vertices'], header['nodes'], header['maskedFaces'] = len(arrays['faces']), len(arrays['vertices']), len(arrays['nodes']), len(arrays['maskedUvs'])
    data = json.dumps(header, separators=(',', ':')).encode()
    prefix = bytearray(struct.pack('<4sI', b'IHD1', len(data)) + data)
    while len(prefix) % 8:
        prefix.append(0)
    raw = prefix + payload
    return raw, gzip.compress(raw, compresslevel=9, mtime=0)

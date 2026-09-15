"""Build a bounded Split floor atlas with original-source blocker sections."""
import argparse
import hashlib
import json
import time
from pathlib import Path
import numpy as np
import shapely
from probe_source_floor_regressions import load_support, source_model
from probe_static_floor_sections import query_box, sections
from static_alpha_sections import masked_section_events


def support_bvh(polygons, ranges):
    boxes = np.array([np.r_[polygons[start:start+count].min(0), polygons[start:start+count].max(0)]
                      for start, count in ranges])
    bounds, nodes, order = [], [], []
    def node(ids):
        index = len(nodes)
        box = np.r_[boxes[ids, :2].min(0), boxes[ids, 2:].max(0)]
        bounds.append(box); nodes.append(None)
        if len(ids) <= 8:
            nodes[index] = [len(order), len(ids), -1, -1]
            order.extend(ids)
        else:
            axis = int(np.argmax(box[2:] - box[:2]))
            ids = ids[np.argsort(boxes[ids, axis] + boxes[ids, axis+2], kind='stable')]
            middle = len(ids) // 2
            nodes[index] = [0, 0, node(ids[:middle]), node(ids[middle:])]
        return index
    node(np.arange(len(boxes)))
    return np.array(bounds), np.array(nodes, dtype=np.int32), np.array(order, dtype=np.int32)


def build(revision, center, radius):
    begin = time.perf_counter()
    support = load_support(revision, 'split', True)
    source = source_model(revision, 'split', True)
    bounds = shapely.box(center[0] - radius, center[1] - radius, center[0] + radius, center[1] + radius)
    cells = support.tree.query(bounds, predicate='intersects')
    cells.sort()
    polygons, polygon_ranges, segment_rows, segment_ranges, segment_faces, fallback = [], [], [], [], [], []
    masked_count = 0
    endpoint_closed = []
    for index, cell in enumerate(cells):
        polygon = np.array(support.polygons[cell].exterior.coords)[:-1]
        polygon_ranges.append([len(polygons), len(polygon)])
        polygons.extend(polygon)
        segment_ranges.append([len(segment_rows), 0])
        fallback.append(False)
        if support.source_ids[cell] < 0:
            continue
        plane = support.planes[cell]
        heights = polygon @ plane[:2] + plane[2] + 1.75
        ids = query_box(source, np.r_[polygon.min(0), heights.min()] - 1e-8,
                        np.r_[polygon.max(0), heights.max()] + 1e-8)
        points = source.arrays['vertices'][source.arrays['faces'][ids]]
        result = sections(points, ids, plane, polygon)
        if result is None:
            fallback[-1] = True
            continue
        segments, faces = result
        for line, face in zip(segments, faces):
            mask = source.arrays['faceMasks'][face]
            if mask < 0:
                rows = [line]
                closed = [[1, 1]]
            else:
                triangle = source.arrays['vertices'][source.arrays['faces'][face]]
                xyz = np.c_[line, line @ plane[:2] + plane[2] + 1.75]
                barycentric = np.linalg.lstsq(np.vstack([triangle.T, np.ones(3)]),
                                             np.c_[xyz, np.ones(2)].T, rcond=None)[0].T
                uv = barycentric @ source.arrays['maskedUvs'][mask]
                policy = source.materials[int(source.arrays['maskedMaterials'][mask])]
                rows, closed = masked_section_events(source.textures[policy['texture']], line, uv, policy)
                masked_count += len(rows)
            segment_rows.extend(rows)
            endpoint_closed.extend(closed)
            segment_faces.extend([face] * len(rows))
        segment_ranges[-1][1] = len(segment_rows) - segment_ranges[-1][0]
        if index % 100 == 0:
            print(index, '/', len(cells), 'patches', len(segment_rows), 'sections', flush=True)
    out = revision / 'local-floor-atlas-v1'
    out.mkdir(exist_ok=True)
    path = out / 'split.npz'
    bvh_bounds, bvh_nodes, bvh_cells = support_bvh(np.array(polygons), polygon_ranges)
    np.savez_compressed(path, supportCells=cells, polygons=np.array(polygons),
                        polygonRanges=np.array(polygon_ranges, dtype=np.int32),
                        planes=support.planes[cells], sourceFaces=support.source_ids[cells],
                        originalTriangles=support.points[cells, :, :2],
                        segments=np.array(segment_rows).reshape(-1, 2, 2),
                        segmentRanges=np.array(segment_ranges, dtype=np.int32),
                        segmentFaces=np.array(segment_faces, dtype=np.int32),
                        segmentEndpointClosed=np.array(endpoint_closed, dtype=np.uint8).reshape(-1, 2),
                        fallback=np.array(fallback, dtype=np.uint8),
                        bvhBounds=bvh_bounds, bvhNodes=bvh_nodes, bvhCells=bvh_cells)
    report = dict(scope=__doc__, sectionFormatVersion=2, center=center, radiusMeters=radius, patches=len(cells),
                  sections=len(segment_rows), maskedOpaqueSections=masked_count,
                  pointSections=sum(bool(np.array_equal(line[0], line[1])) for line in segment_rows),
                  openSectionEndpoints=int((np.array(endpoint_closed) == 0).sum()),
                  coplanarFallbackPatches=sum(fallback), compressedBytes=path.stat().st_size,
                  buildSeconds=time.perf_counter()-begin,
                  dataSha256=hashlib.sha256(path.read_bytes()).hexdigest(),
                  compilerSha256={name: hashlib.sha256(Path(__file__).with_name(name).read_bytes()).hexdigest()
                                  for name in ['build_local_floor_atlas.py', 'probe_static_floor_sections.py', 'static_alpha_sections.py']},
                  supportSha256=hashlib.sha256((revision / 'source-floor-support-all-walkable-v1/split.floor-support.npz').read_bytes()).hexdigest(),
                  sourceSha256=hashlib.sha256((revision / 'full-height-input-v1/split/split.height.bin.gz').read_bytes()).hexdigest(),
                  limitation='Bounded native-coordinate atlas; no terrain roles certified for Split. Original source fallback remains required after a floor gap or on a coplanar section.')
    (out / 'split.json').write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(report), flush=True)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('revision', type=Path)
    parser.add_argument('--center', type=float, nargs=2, default=[20.599371111492427, 39.59257844288108])
    parser.add_argument('--radius', type=float, default=6.)
    args = parser.parse_args()
    build(args.revision, args.center, args.radius)

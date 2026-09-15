"""Test finite coplanar unions while retaining every failed group unchanged.

This produces an offline replacement mesh and source assignment, not an app
pack. Original masked faces always remain in the residual geometry.
"""
import argparse
import json
from pathlib import Path
import time

import numpy as np
import shapely

from inventory_opaque_plane_groups import sha
from tactical_alignment_audit import pack


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('inventory', type=Path)
    parser.add_argument('out', type=Path)
    parser.add_argument('--minimum-faces', type=int, default=100)
    args = parser.parse_args()
    args.out.mkdir(parents=True, exist_ok=False)
    started = time.perf_counter()
    meta = json.loads((args.inventory/'report.json').read_bytes())
    source = Path(meta['sourcePack'])
    if sha(source) != meta['sourcePackSha256']:
        raise ValueError('Source pack changed')
    assignment = args.inventory/'plane-groups.npz'
    if sha(assignment) != meta['assignmentSha256']:
        raise ValueError('Plane assignments changed')
    with np.load(assignment) as data:
        planes, groups, counts = data['planes'], data['faceGroups'], data['counts']
    _, scene = pack(source)
    triangles = scene['vertices'][scene['faces']]
    source_replaced = np.zeros(len(groups), dtype=bool)
    output, output_groups, records = [], [], []
    for group in np.flatnonzero(counts >= args.minimum_faces):
        ids = np.flatnonzero(groups == group)
        assert np.all(scene['faceMasks'][ids] < 0)
        plane = planes[group]
        dropped = int(np.abs(plane[:3]).argmax())
        axes = [axis for axis in range(3) if axis != dropped]
        xy = triangles[ids][:, :, axes]
        row = dict(group=int(group), sourceFaces=len(ids), droppedAxis=dropped)
        try:
            original = shapely.union_all(shapely.polygons(xy))
            if not original.is_valid:
                raise ValueError('Invalid source union')
            # Tolerance zero removes only exactly collinear polygon vertices.
            region = shapely.simplify(original, 0, preserve_topology=True)
            if original.symmetric_difference(region).area != 0:
                raise ValueError('Zero-tolerance simplification changed area')
            children = []
            for poly in shapely.get_parts(region):
                children.extend(shapely.get_parts(shapely.constrained_delaunay_triangles(poly)))
            union = shapely.union_all(children)
            error = original.symmetric_difference(union).area
            overlap = abs(sum(c.area for c in children)-union.area)
            boundary_error = original.boundary.hausdorff_distance(union.boundary)
            holes_before = sum(len(p.interiors) for p in shapely.get_parts(original))
            holes_after = sum(len(p.interiors) for p in shapely.get_parts(union))
            # Preserve failed or non-reducing groups in full; there is no
            # fallback that fills holes or discards thin source fragments.
            limit = max(1e-12, original.area*1e-12)
            if error > limit or overlap > limit:
                raise ValueError(f'Coverage or overlap error: {error}, {overlap}')
            if holes_before != holes_after:
                raise ValueError('Finite hole topology changed')
            if boundary_error > 1e-10:
                raise ValueError('Finite boundary moved')
            if len(children) >= len(ids):
                raise ValueError('No triangle reduction')
            rebuilt = np.zeros((len(children), 3, 3))
            for index, child in enumerate(children):
                coords = np.asarray(child.exterior.coords)[:3]
                rebuilt[index, :, axes[0]] = coords[:, 0]
                rebuilt[index, :, axes[1]] = coords[:, 1]
                rebuilt[index, :, dropped] = (plane[3]-coords@plane[axes])/plane[dropped]
            reconstructed = (plane[3]-xy@plane[axes])/plane[dropped]
            vertex_change = float(np.abs(reconstructed-triangles[ids, :, dropped]).max())
            if vertex_change > 2e-10:
                raise ValueError('Source coordinate reconstruction exceeded bound')
            source_replaced[ids] = True
            output.extend(rebuilt)
            output_groups.extend([int(group)]*len(rebuilt))
            row.update(accepted=True, outputFaces=len(children),
                footprintDifference=error, interiorOverlap=overlap,
                sourceArea=original.area, maximumCoordinateChangeMeters=vertex_change,
                boundaryHausdorff=boundary_error,
                holesBefore=holes_before, holesAfter=holes_after)
        except (ValueError, shapely.errors.GEOSException) as exc:
            row.update(accepted=False, reason=str(exc))
        records.append(row)
    target = args.out/'compact-planes.npz'
    np.savez_compressed(target, triangles=np.asarray(output, dtype='<f8').reshape(-1, 3, 3),
        outputPlaneGroups=np.asarray(output_groups, dtype='<i4'),
        replacedSourceFaces=np.flatnonzero(source_replaced),
        residualSourceFaces=np.flatnonzero(~source_replaced))
    accepted = [r for r in records if r['accepted']]
    report = dict(scope=__doc__, sourcePackSha256=sha(source),
        inventorySha256=sha(assignment), scriptSha256=sha(Path(__file__)),
        sourceFaces=len(triangles), replacedSourceFaces=int(source_replaced.sum()),
        replacementFaces=len(output), residualSourceFaces=int((~source_replaced).sum()),
        totalResultFaces=int((~source_replaced).sum())+len(output),
        acceptedGroups=len(accepted), retainedGroups=len(records)-len(accepted),
        outputBytes=target.stat().st_size, outputSha256=sha(target),
        maximumCoordinateChangeMeters=max((r['maximumCoordinateChangeMeters'] for r in accepted), default=0),
        maximumBoundaryHausdorff=max((r['boundaryHausdorff'] for r in accepted), default=0),
        elapsedSeconds=time.perf_counter()-started, groups=records,
        productionPromotion=False,
        limitations=['Floating polygon arithmetic requires independent ray and contact checks before adoption.',
            'Output byte count includes assignment IDs but excludes residual world geometry and alpha textures.',
            'No BVH, application rendering, or frame-time benchmark is included.'])
    (args.out/'report.json').write_text(json.dumps(report, indent=2)+'\n')
    print(json.dumps({k:v for k,v in report.items() if k not in ['scope','groups','limitations']}), flush=True)


if __name__ == '__main__':
    main()

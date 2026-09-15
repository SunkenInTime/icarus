"""Inspect original-height barrier profiles under the frozen V29 declaration.

This uses original retained source faces, not relative-floor candidate Z. The
section intersections are numerical diagnostics; independent source partition,
attribute, and original-height oracle proofs remain separate requirements.
"""
import gzip
import hashlib
import json
from pathlib import Path

import numpy as np
import shapely

from authored_region_cells import barycentric
from render_split_remaining_corner_families import sections
from tactical_alignment_audit import pack

ROOT = Path('E:/IcarusWorldAudit/2026-09-06')
REV = ROOT/'tactical-visibility-revision'


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    candidate = REV/'split-wall-family-normalized-candidate-v29'
    output = candidate/'barrier-original-height-sections'
    output.mkdir(exist_ok=False)
    binding_path = candidate/'bindings.json'
    binding = json.loads(binding_path.read_text())
    family = next(row for row in binding['families'] if row['edge']==200123)
    raw_path = ROOT/'supplemented-v2/world/split/geometry.npz'
    raw = np.load(raw_path)
    full_path = REV/'full-height-input-v1/split/split.height.bin.gz'
    _, full = pack(full_path)
    correspondence = np.load(full_path.parent/'source-correspondence.npz')['sourceFaces']
    raw_ids = np.asarray(family['reviewedSourceFaces'])
    retained = np.isin(raw_ids, correspondence)
    selected = raw_ids[retained]
    masked_ids = set(correspondence[full['faceMasks']>=0].tolist())
    assert not (set(selected.tolist()) & masked_ids), 'Masked sections need alpha-aware evidence'
    triangles = raw['points'][raw['faces'][selected]].astype(float)
    warp_path = REV/'display-warps-v1/split.display-warp.json.gz'
    warp = json.loads(gzip.decompress(warp_path.read_bytes()))
    matrix = np.column_stack((warp['projection']['axisU'],warp['projection']['axisV']))
    origin = np.asarray(warp['projection']['origin'])
    triangles[:,:,:2] = triangles[:,:,:2] @ matrix.T + origin
    source = np.asarray(family['sourceVerticesSvg'])
    target = np.asarray(family['targetVerticesSvg'])
    cells = np.asarray(family['triangles'], dtype=int)
    polygons = shapely.polygons(source[cells])
    tree = shapely.STRtree(polygons)
    box = shapely.box(*family['box'])
    tested_spans = list(family['reviewedAuthoredSpans']) + [
        dict(completeSpan='122-lower-continuation', startSvg=[338.617,264.145], endSvg=[338.617,270.])]
    heights = []
    for height in [5.5,6.75,7.25,8.25,9.75,11.75,15.75,20.]:
        original_lines, source_rows = sections(triangles,height)
        mapped, parents, declared_cells = [], [], []
        for line, source_row in zip(original_lines,source_rows):
            clipped = shapely.LineString(line).intersection(box)
            if clipped.is_empty:
                continue
            for cell in tree.query(clipped,predicate='intersects'):
                for piece in shapely.get_parts(clipped.intersection(polygons[cell])):
                    if piece.geom_type not in ('LineString','Point'):
                        raise ValueError(piece.geom_type)
                    xy = shapely.get_coordinates(piece)
                    if not len(xy):
                        continue
                    weights = barycentric(xy,source[cells[cell]])
                    mapped_xy = target[cells[cell,0]] + weights[:,1:] @ (target[cells[cell,1:]]-target[cells[cell,0]])
                    mapped.append([mapped_xy[0],mapped_xy[-1]])
                    parents.append(int(selected[source_row]))
                    declared_cells.append(int(cell))
        mapped = np.asarray(mapped).reshape(-1,2,2)
        spans = []
        for span in tested_spans:
            a,b = np.asarray([span['startSvg'],span['endSvg']])
            tangent = b-a
            length = np.linalg.norm(tangent)
            tangent /= length
            normal = np.array([-tangent[1],tangent[0]])
            relative = mapped-a
            distance = relative@normal
            along = relative@tangent
            same_plane = np.abs(distance).max(axis=1)<=1e-7
            intervals = []
            relevant_faces = []
            for index in np.flatnonzero(same_plane):
                low, high = np.clip(np.sort(along[index]),0,length)
                if high>low:
                    intervals.append(shapely.LineString([[low,0],[high,0]]))
                    relevant_faces.append(parents[index])
            union = shapely.union_all(intervals)
            spans.append(dict(completeSpan=span['completeSpan'], lengthSvg=float(length),
                coveredLengthSvg=float(union.length),
                intervals=[[float(p.coords[0][0]),float(p.coords[-1][0])] for p in shapely.get_parts(shapely.line_merge(union))],
                rawSourceFaces=sorted(set(relevant_faces))))
        np.savez_compressed(output/f'absolute-z-{height:g}.npz', mappedSectionsSvg=mapped,
                            originalRawFaces=np.asarray(parents), regionCells=np.asarray(declared_cells))
        heights.append(dict(absoluteHeightMeters=height,sourceSections=len(original_lines),
                            mappedSections=len(mapped),spans=spans))
    report = dict(scope=__doc__, rawGeometrySha256=sha(raw_path), fullSourcePackSha256=sha(full_path),
        candidatePackSha256=sha(candidate/'split.height.bin.gz'), bindingsSha256=sha(binding_path),
        scriptSha256=sha(Path(__file__)), declaredRawFaces=len(raw_ids), retainedRawFaces=len(selected),
        sourcePolicyExcludedRawFaces=raw_ids[~retained].tolist(), numericalContactBandSvg=1e-7,
        sections=heights, floorPolicyCertified=False)
    (output/'report.json').write_text(json.dumps(report,indent=2))
    for row in heights:
        print(row['absoluteHeightMeters'],[(s['completeSpan'],round(s['coveredLengthSvg'],8)) for s in row['spans']],flush=True)


if __name__=='__main__':
    main()

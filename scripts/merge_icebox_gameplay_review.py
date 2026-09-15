"""Combine reviewed Icebox wall profiles and the two B bridge levels."""
import gzip
import json
import numpy as np
import shapely

from audit_svg_source_height_associations import REV
from build_split_svg_ground import triangulated_parts
from compile_reviewed_svg_height_map import compile_map


def main():
    output = REV / 'icebox-gameplay-audit-v3'
    followup = REV / 'icebox-gameplay-structural-followup-v3'
    decisions = json.loads((output / 'icebox-decisions.json').read_text())
    patch = json.loads((followup / 'proposed-patch.json').read_text())
    reviewed = {r['wallId'] for r in json.loads((output / 'opening-evidence.json').read_text())}
    walls = {w['wallId']: w for w in decisions['walls']}
    for row in patch['wallPatches']:
        assert row['wallId'] not in reviewed, row['wallId']
        assert row['operation'] == 'replace-parts'
        walls[row['wallId']]['parts'] = row['parts']

    bridge = json.loads((followup / 'bridge-layer-patch.json').read_text())
    ground = json.loads(gzip.decompress(open(decisions['groundModel'], 'rb').read()))
    vertices = np.array(ground['vertices']).reshape(-1, 3)
    faces = np.array(ground['triangles']).reshape(-1, 3)
    original = vertices[faces]
    upper = np.array([t['verticesNativeMeters'] for t in bridge['upperPrimaryGroundPatch']['triangles']]).reshape(-1, 3, 3)
    covered = shapely.union_all(shapely.polygons(upper[:, :, :2]))
    domain = shapely.union_all(shapely.polygons(original[:, :, :2]))
    assert covered.difference(domain).area < 1e-7
    result = list(upper)
    for tri in original:
        shape = shapely.Polygon(tri[:, :2])
        if not shape.intersects(covered):
            result.append(tri)
            continue
        plane = np.linalg.solve(np.c_[tri[:, :2], np.ones(3)], tri[:, 2])
        for piece in triangulated_parts(shape.difference(covered)):
            xy = np.array(piece.exterior.coords[:-1])
            result.append(np.c_[xy, np.c_[xy, np.ones(3)] @ plane])
    result = np.array(result)
    assert domain.symmetric_difference(shapely.union_all(shapely.polygons(result[:, :, :2]))).area < 1e-6
    ground.update(vertices=result.reshape(-1).tolist(), triangles=list(range(len(result) * 3)))
    ground.setdefault('sourceObjects', []).append(4237)
    ground_path = output / 'icebox-ground-final.json.gz'
    ground_path.write_bytes(gzip.compress(json.dumps(ground, separators=(',', ':')).encode(), mtime=0))
    decisions.update(groundModel=str(ground_path), groundReviewStatus='reviewed')
    decisions['supports'].append(bridge['explicitLowerSupport'])
    decisions['structuralFollowup'] = str(followup / 'proposed-patch.json')
    decisions['bridgeLayerReview'] = str(followup / 'bridge-layer-patch.json')
    path = output / 'icebox-final-decisions.json'
    path.write_text(json.dumps(decisions, separators=(',', ':')))
    print(json.dumps(compile_map('icebox', path, output / 'models-final', False)))


if __name__ == '__main__':
    main()

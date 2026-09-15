"""Audit chart switches along original walking portals, using source triangles."""
import argparse
import gzip
import json
from pathlib import Path
import numpy as np
import shapely
from audit_tactical_target_rays import ReferenceModel
from build_global_tactical_candidate import GroundField
from verify_tactical_transform import source_cast


def verify(revision, name):
    nav = json.loads(gzip.decompress((revision / 'baseline-world' / (name + '_navigation.json.gz')).read_bytes()))
    selection = json.loads((revision / 'sheet-selection-v1' / (name + '.json')).read_text())
    ui = json.loads(Path('assets/maps/world/height_catalog.json').read_text())['maps'][name]['uiTransform']
    def native_xy(uv):
        return np.array([(uv[1] - ui['YScalarToAdd']) / (100 * ui['YMultiplier']),
                         -(uv[0] - ui['XScalarToAdd']) / (100 * ui['XMultiplier'])])
    vertices = np.array(nav['vertices'], dtype=float).reshape(-1, 3)
    vertices[:, :2] = np.array([native_xy(v[:2] / nav['coordinateScale']) for v in vertices])
    vertices[:, 2] = np.array(nav['refinedFloorHeightsCm']) / 100
    original_triangles = np.array(nav['triangles']).reshape(-1, 4)
    def floor_height(parent, xy):
        admitted = []
        for _, a, b, c in original_triangles[original_triangles[:, 0] == parent]:
            tri = vertices[[a, b, c]]
            if shapely.Polygon(tri[:, :2]).buffer(1e-8).covers(shapely.Point(xy)):
                admitted.append(float(np.r_[xy, 1] @ np.linalg.solve(np.c_[tri[:, :2], np.ones(3)], tri[:, 2])))
        if not admitted:
            raise ValueError('Walking test leaves original nav parent')
        return max(admitted)
    source = ReferenceModel(revision / 'full-height-input-v1' / name / (name + '.height.bin.gz'))
    fields = [GroundField(revision / 'global-ground-v1' / (name + '.tactical-ground.json.gz')),
              GroundField(revision / 'upper-ground-v2' / (name + '.tactical-ground.json.gz'))]
    links = np.array(nav['links']).reshape(-1, 6)
    results = []
    for boundary in selection['variantBoundaryPortals']:
        a, b = boundary['parents']
        link = links[(links[:, 0] == a) & (links[:, 1] == b)][0]
        midpoint = native_xy((link[2:4] + link[4:6]) / (2 * nav['coordinateScale']))
        centers = np.array(boundary['centers'])
        samples = []
        for parent, center in zip((a, b), centers):
            xy = midpoint * .98 + center[:2] * .02
            world_z = floor_height(parent, xy) + 1.75
            differences = []
            field_heights = [float(f.heights(xy[None])[0]) for f in fields]
            for angle in np.linspace(0, 2 * np.pi, 48, endpoint=False):
                hits, ranges = [], []
                for field, reference in zip(fields, field_heights):
                    origin = np.r_[xy, world_z - reference]
                    target = np.r_[xy + np.array([np.cos(angle), np.sin(angle)]) * 43, origin[2]]
                    hit = source_cast(source, field, origin, target)
                    hits.append(hit)
                    ranges.append(43. if hit is None else float(np.linalg.norm(np.array(hit['point'][:2]) - xy)))
                if abs(ranges[1] - ranges[0]) > .01 or (hits[0] is None) != (hits[1] is None):
                    differences.append(dict(angle=float(angle), hitDistancesMeters=ranges,
                                            changedVisibility=(hits[0] is None) != (hits[1] is None), sourceHits=hits))
            samples.append(dict(parent=parent, selectedChart=selection['parentVariants'][parent], worldOrigin=[*xy, world_z],
                                referenceHeights=field_heights, differingDirections=differences))
        results.append(dict(parents=[a, b], midpoint=midpoint.tolist(), samples=samples))
        print(a, b, 'differences', [len(s['differingDirections']) for s in samples], flush=True)
    report = dict(map=name, directionsPerPose=48, portals=len(results),
                  scope='Both charts evaluated at identical walking poses; differences quantify potential switching discontinuities.', boundaries=results)
    (revision / 'sheet-selection-v1' / (name + '-walking-boundaries.json')).write_text(json.dumps(report, indent=2) + '\n')
    return report


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('revision', type=Path)
    parser.add_argument('map')
    args = parser.parse_args()
    verify(args.revision, args.map)

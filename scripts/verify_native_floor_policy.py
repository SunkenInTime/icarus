"""Run analytic floor-policy cases through both Python and native selectors.

All source intersections deliberately use the same small analytic scenes here.
The separate local atlas test checks precomputed sections against original 3D.
"""
import argparse
from pathlib import Path
import unittest
from unittest.mock import patch
import numpy as np
from build_local_floor_atlas import support_bvh
from probe_source_floor_support import SourceSupport
from verify_native_floor_atlas import NativeAtlas


def run(revision):
    atlas = NativeAtlas(revision)
    original = SourceSupport.cast
    comparisons = []
    def checked(support, source, origin, direction, distance, *args, **kwargs):
        expected = original(support, source, origin, direction, distance, *args, **kwargs)
        polygons, ranges = [], []
        for polygon in support.polygons:
            points = np.array(polygon.exterior.coords)[:-1]
            ranges.append([len(polygons), len(points)]); polygons.extend(points)
        polygons = np.array(polygons); ranges = np.array(ranges, dtype=np.int32)
        bounds, nodes, cells = support_bvh(polygons, ranges)
        terrain_ids = kwargs.get('terrain_source_faces', args[5] if len(args) > 5 else ())
        raised_ids = kwargs.get('raised_source_faces', args[6] if len(args) > 6 else ())
        roles = np.zeros(len(support.source_ids), dtype=np.uint8)
        roles[np.isin(support.source_ids, list(terrain_ids))] = 1
        roles[np.isin(support.source_ids, list(raised_ids))] = 2
        atlas.arrays = dict(polygons=polygons, polygonRanges=ranges, planes=support.planes,
                            originalTriangles=support.points[:, :, :2],
                            sourceFaces=np.asarray(support.source_ids, dtype=np.int64), terrain=roles,
                            segments=np.empty((0, 2, 2)), segmentRanges=np.zeros((len(roles), 2), dtype=np.int32),
                            segmentEndpointClosed=np.empty((0,2), dtype=np.uint8), endpointTolerance=np.empty(0),
                            segmentFaces=np.empty(0, dtype=np.int32), fallback=np.ones(len(roles), dtype=np.uint8),
                            bvhBounds=bounds, bvhNodes=nodes, bvhCells=cells)
        atlas.arrays.update(transitPolygons=np.empty((0,2)),transitRanges=np.empty((0,2),dtype=np.int32),
                           transitGroups=np.empty(0,dtype=np.int32),transitSheets=np.empty(0,dtype=np.int32),
                           transitCellGroups=np.full(len(roles),-1,dtype=np.int32),transitAdjacency=np.empty((0,0),dtype=np.uint8))
        atlas.arrays = {key: np.ascontiguousarray(value) for key, value in atlas.arrays.items()}
        actual = atlas.cast(source, origin, direction, distance)
        error = abs(actual['distanceMeters'] - expected['distanceMeters'])
        comparisons.append(error)
        if error > 1e-8:
            raise AssertionError(f'Native floor selection differs by {error} m: {actual} versus {expected}')
        return expected
    with patch.object(SourceSupport, 'cast', checked):
        suite = unittest.defaultTestLoader.discover('scripts', pattern='test_source_floor_selection.py')
        result = unittest.TextTestRunner().run(suite)
    if not result.wasSuccessful():
        raise SystemExit(1)
    print(f'{len(comparisons)} Python/native analytic comparisons; maximum distance difference {max(comparisons):.12g} m')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('revision', type=Path)
    run(parser.parse_args().revision)

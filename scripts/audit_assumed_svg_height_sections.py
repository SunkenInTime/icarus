"""Measure local vertical source sections for every assumed SVG wall.

This covers the complete inventory, including walls with no raised-ray finding.
It records actual face intervals and source identities instead of assigning a
maximum building height to an unrelated piece of ink. Measurement is separate
from accepting an association or a gameplay opening.
"""
import argparse
from collections import Counter
from functools import lru_cache
import hashlib
import json
from pathlib import Path
import time

import numpy as np
import shapely

from audit_all_map_gameplay_levels import MAPS, ROOT, read
from compile_reviewed_svg_height_map import polygon
from derive_svg_height_candidates import excluded
from inventory_assumed_svg_heights import DESTINATION
from svg_review_source import source_world, verified_source_pack


def clipped_height_intervals(triangles, origin, tangent, half_along, half_cross, include_flat=False):
    """Exact Z extrema of triangles clipped to an oriented XY rectangle."""
    normal = np.array([-tangent[1], tangent[0]])
    q = triangles.copy()
    q[:, :, 0] = (triangles[:, :, :2] - origin) @ tangent
    q[:, :, 1] = (triangles[:, :, :2] - origin) @ normal
    bound = np.array([half_along, half_cross])
    z = []
    inside = np.all(abs(q[:, :, :2]) <= bound + 1e-12, axis=2)
    z.append(np.where(inside, q[:, :, 2], np.nan))
    for axis in [0, 1]:
        for limit in [-bound[axis], bound[axis]]:
            a, b = q, np.roll(q, -1, axis=1)
            denominator = b[:, :, axis] - a[:, :, axis]
            fraction = np.divide(limit - a[:, :, axis], denominator,
                out=np.full_like(denominator, np.nan), where=abs(denominator) > 1e-14)
            hits = a + fraction[:, :, None] * (b - a)
            valid = (fraction >= 0) & (fraction <= 1)
            valid &= abs(hits[:, :, 1 - axis]) <= bound[1 - axis] + 1e-12
            z.append(np.where(valid, hits[:, :, 2], np.nan))
    # An XY rectangle corner can be inside a sloping triangle even when none
    # of the triangle's vertices or edges falls inside the rectangle.
    a, u, v = q[:, 0], q[:, 1] - q[:, 0], q[:, 2] - q[:, 0]
    determinant = u[:, 0] * v[:, 1] - u[:, 1] * v[:, 0]
    for x in [-half_along, half_along]:
        for y in [-half_cross, half_cross]:
            dx, dy = x - a[:, 0], y - a[:, 1]
            s = np.divide(dx * v[:, 1] - dy * v[:, 0], determinant,
                out=np.full_like(determinant, np.nan), where=abs(determinant) > 1e-14)
            t = np.divide(u[:, 0] * dy - u[:, 1] * dx, determinant,
                out=np.full_like(determinant, np.nan), where=abs(determinant) > 1e-14)
            valid = (s >= -1e-12) & (t >= -1e-12) & (s + t <= 1 + 1e-12)
            z.append(np.where(valid, a[:, 2] + s * u[:, 2] + t * v[:, 2], np.nan)[:, None])
    values = np.concatenate(z, axis=1)
    present = np.isfinite(values).any(axis=1)
    low = np.min(np.where(np.isfinite(values), values, np.inf), axis=1)
    high = np.max(np.where(np.isfinite(values), values, -np.inf), axis=1)
    keep = present & ((high - low > 1e-6) | include_flat)
    return np.flatnonzero(keep), np.column_stack((low[keep], high[keep]))


def merge_intervals(values, gap=1e-5):
    result = []
    for low, high in sorted(values, key=lambda row: (row[0], row[1])):
        if result and low <= result[-1][1] + gap:
            result[-1][1] = max(result[-1][1], float(high))
        else:
            result.append([float(low), float(high)])
    return result


def wall_stations(wall, spacing=2.0):
    for ring_index, raw in enumerate(wall['rings']):
        line = shapely.LineString(np.asarray(raw).reshape(-1, 2))
        if not line.is_ring:
            line = shapely.LineString([*line.coords, line.coords[0]])
        count = max(1, int(np.ceil(line.length / spacing)))
        for index in range(count):
            distance = (index + .5) * line.length / count
            p = np.asarray(line.interpolate(distance).coords[0])
            a = np.asarray(line.interpolate(max(0, distance - .01)).coords[0])
            b = np.asarray(line.interpolate(min(line.length, distance + .01)).coords[0])
            tangent = b - a
            if np.linalg.norm(tangent) < 1e-9:
                continue
            yield ring_index, distance, p, tangent / np.linalg.norm(tangent)


def audit(name, output=DESTINATION):
    started = time.monotonic()
    folder = output / name
    inventory = read(folder / 'assumed-height-review.json')
    model = read(folder / 'before-attack.json.gz')
    source_path = source_world(name) / 'geometry.npz'
    metadata_path = source_path.with_suffix('.json')
    objects = read(metadata_path)['objects']
    archive = np.load(source_path)
    points, faces = archive['points'], archive['faces']
    pack = verified_source_pack(name)
    alignment_path = ROOT / f'tactical-alignment-sides-v1/{name}.json'
    matrix = np.asarray(read(alignment_path)['nativeToAttackSvg'])
    inverse = np.linalg.inv(matrix[:, :2])
    eligible = [i for i, obj in enumerate(objects)
                if obj['faceCount'] and not excluded(obj['path'])]
    bounds = np.asarray([objects[i]['boundsMeters'] for i in eligible])
    tree = shapely.STRtree(shapely.box(bounds[:, 0, 0], bounds[:, 0, 1],
                                      bounds[:, 1, 0], bounds[:, 1, 1]))

    @lru_cache(maxsize=128)
    def triangles(oid):
        obj = objects[oid]
        ids = np.arange(obj['firstFace'], obj['firstFace'] + obj['faceCount'])
        ids = ids[pack['retained'][ids]]
        tri = points[faces[ids]].astype(float)
        return ids, tri, tri[:, :, :2].min(1), tri[:, :, :2].max(1)

    records = []
    for wall in inventory['records']:
        stations = []
        source_counts = Counter()
        for ring, distance, svg, svg_tangent in wall_stations(wall):
            native = (svg - matrix[:, 2]) @ inverse.T
            tangent = inverse @ svg_tangent
            tangent /= np.linalg.norm(tangent)
            radius = .75
            local = []
            for index in tree.query(shapely.box(*(native - radius), *(native + radius))):
                oid = eligible[index]
                ids, tri, low, high = triangles(oid)
                if not len(ids):
                    continue
                near = np.flatnonzero(np.all(low <= native + radius, axis=1)
                                      & np.all(high >= native - radius, axis=1))
                if not len(near):
                    continue
                retained, intervals = clipped_height_intervals(tri[near], native, tangent, .15, .6)
                if not len(retained):
                    continue
                merged = merge_intervals(intervals)
                local.append(dict(object=oid, bands=merged,
                                  sourceFaces=ids[near[retained]].tolist(),
                                  maskedFaces=ids[near[retained]][pack['masked'][ids[near[retained]]]].tolist()))
                source_counts[oid] += 1
            combined = merge_intervals([band for row in local for band in row['bands']])
            stations.append(dict(ring=ring, distanceSvg=distance, svg=svg.tolist(),
                                 native=native.tolist(), sourceSections=local,
                                 combinedGeometryBands=combined))
        row = dict(wallId=wall['wallId'], status='measured-unaccepted',
            priorRayFindings=wall['priorRayFindings'], boundsSvg=wall['boundsSvg'],
            floorElevationMeters=wall['floorElevationMeters'], stations=stations,
            sourceObjects=[dict(object=oid, path=objects[oid]['path'], stations=count,
                                boundsMeters=objects[oid]['boundsMeters'])
                           for oid, count in source_counts.most_common()],
            withoutSourceSection=sum(not s['sourceSections'] for s in stations))
        records.append(row)
        print(name, len(records), '/', len(inventory['records']), wall['wallId'],
              len(stations), 'sections', row['withoutSourceSection'], 'unmatched', flush=True)
    report = dict(schemaVersion=1, map=name, records=records,
        assetSha256=inventory['assetSha256'], sourceGeometryFile=str(source_path),
        sourceGeometrySha256=hashlib.sha256(source_path.read_bytes()).hexdigest(),
        sourceMetadataSha256=hashlib.sha256(metadata_path.read_bytes()).hexdigest(),
        alignmentSha256=hashlib.sha256(alignment_path.read_bytes()).hexdigest(),
        spacingSvg=2., sectionHalfAlongMeters=.15, sectionHalfCrossMeters=.6,
        sourcePackVerification=pack['proof'],
        elapsedSeconds=time.monotonic() - started,
        limitations=['Raw geometric sections do not establish masked-material opacity.',
                     'Adjacent source geometry requires association review; no runtime wall is changed.',
                     'Every original assumed record is measured, including those without a ray discrepancy.'])
    (folder / 'assumed-height-sections.json').write_text(json.dumps(report, separators=(',', ':')))
    print(json.dumps(dict(map=name, walls=len(records),
        sections=sum(len(r['stations']) for r in records), seconds=report['elapsedSeconds'])), flush=True)
    return report


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('maps', nargs='*', default=MAPS)
    parser.add_argument('--output', type=Path, default=DESTINATION)
    args = parser.parse_args()
    for name in args.maps:
        audit(name, args.output)

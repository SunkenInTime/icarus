"""Measure confirmed wall contacts in actual SVG-ink and visibility rasters.

Ink is not a blocker classifier. These bounded Split spans were identified in
the user's rejected views; the Clove throat is a separate preserved opening.
The tool reports raster blank runs separately from shadow-mesh geometry.
"""
import argparse
import gzip
import hashlib
import json
from pathlib import Path

import numpy as np
from PIL import Image
import shapely

from tactical_alignment_composite import IndexedTriangles


SOLID_SPANS = [
    dict(id='ramp-1-forward', label='south corridor top structural wall',
         attackSpan=[[300., 310.928], [340., 310.928]], inward=[0., 1.]),
    dict(id='annotated-deadlock', label='defender corridor top structural wall',
         attackSpan=[[260., 83.9221], [296., 83.9221]], inward=[0., 1.]),
    dict(id='annotated-clove', label='mid upper structural wall',
         attackSpan=[[225., 182.274], [240., 182.274]], inward=[0., 1.]),
]


def pixel_gap(ink, visibility, ys, wall_y, inward, scale, threshold=1):
    """Integer pixel blank runs; AA coverage is retained at threshold 1/255."""
    t = ((ys + .5) - wall_y) * inward
    order = np.argsort(t)
    ys, t = ys[order], t[order]
    near_wall = (abs(t) <= 1.5 * scale) & (ink[ys] >= threshold)
    if not near_wall.any():
        return None
    wall_end = int(np.flatnonzero(near_wall)[-1])
    lit = np.flatnonzero((t >= -1.5 * scale) & (visibility[ys] >= threshold))
    if not len(lit):
        return dict(blankPixels=None, status='no-cone-in-profile')
    first_lit = int(lit[0])
    result = dict(blankPixels=max(0, first_lit - wall_end - 1), status='measured',
                inkLastPixel=int(ys[wall_end]), coneFirstPixel=int(ys[first_lit]),
                inkAlpha=int(ink[ys[wall_end]]), coneAlpha=int(visibility[ys[first_lit]]))
    ink_body = np.flatnonzero((abs(t) <= 1.5 * scale) & (ink[ys] >= 128))
    cone_body = np.flatnonzero((t >= -1.5 * scale) & (visibility[ys] >= 128))
    if not len(ink_body) or not len(cone_body):
        result.update(halfCoverageSeparationPixels=None, coverageDeficitPixels=None,
                      coverageContactPassed=False)
        return result
    body_start, body_end = int(ink_body[-1]) + 1, int(cone_body[0])
    between = ys[body_start:body_end] if body_end > body_start else np.array([], dtype=int)
    # Sum the independently measured covered pixel areas, clamped to one.
    # This is a contact-area metric, not an alpha-over compositing prediction.
    # At most one uncertain pixel is allowed, with >=50% combined coverage;
    # two 8-bit quantization levels account for rounding in the two masks.
    combined = np.minimum(1., (ink[between].astype(float) + visibility[between]) / 255.)
    deficit = float((1 - combined).sum())
    result.update(halfCoverageSeparationPixels=len(between),
                  coverageDeficitPixels=deficit,
                  minimumCombinedContactCoverage=float(combined.min()) if len(combined) else 1.,
                  coverageContactPassed=bool(len(between) <= 1 and deficit <= .5 + 2 / 255.))
    return result


class PhysicalGeometry:
    def __init__(self, warp, row, mesh):
        self.row = row
        self.warp = warp
        self.target = np.array(warp['targetAttackSvg']).reshape(-1, 2)
        self.source = np.array(warp['sourceNativeMeters']).reshape(-1, 2)
        self.indices = np.array(warp['triangles']).reshape(-1, 3)
        self.tri = IndexedTriangles(self.target, self.indices)
        self.shadow = shapely.STRtree(shapely.polygons(mesh.reshape(-1, 3, 2)))
        self.q = np.array(row['query'])

    def native(self, xy):
        xy = np.atleast_2d(xy)
        attack = np.array(self.warp['attackToDefenseSvg']['origin']) - xy if self.row['side'] == 'defense' else xy
        cells = self.tri.find_simplex(attack)
        if np.any(cells < 0):
            raise ValueError('Wall fixture escaped the bound display mesh')
        transform = self.tri.transform[cells]
        uv = np.einsum('nij,nj->ni', transform[:, :2], attack - transform[:, 2])
        bary = np.c_[uv, 1 - uv.sum(1)]
        return np.einsum('ni,nij->nj', bary, self.source[self.indices[cells]])

    def in_frustum(self, xy, margin=True):
        delta = self.native(xy) - self.q[:2]
        distance = np.linalg.norm(delta, axis=1)
        cos = delta @ self.q[3:5] / distance
        return (distance < self.q[5] - (.1 if margin else 0)) & (cos > np.cos(self.q[6] / 2 - (.01 if margin else 0)))

    def clear(self, xy):
        delta = self.native(xy) - self.q[:2]
        points, _ = self.shadow.query(shapely.points(delta), predicate='intersects')
        clear = np.ones(len(delta), dtype=bool)
        clear[points] = False
        return clear


def run(folder, fixtures=None):
    manifest_bytes = (folder / 'manifest.json').read_bytes()
    manifest = json.loads(manifest_bytes)
    warp_bytes = Path(manifest['displayWarpFile']).read_bytes()
    assert hashlib.sha256(warp_bytes).hexdigest() == manifest['displayWarpSha256']
    warp = json.loads(gzip.decompress(warp_bytes))
    records, openings = [], []
    for row in manifest['cases']:
        fixture = next(f for f in (fixtures if fixtures is not None else SOLID_SPANS) if f['id'] == row['id'])
        span = np.array(fixture['attackSpan'])
        inward = np.array(fixture['inward'])
        along_axis = int(np.argmax(abs(span[1] - span[0])))
        normal_axis = 1 - along_axis
        assert abs(span[1, normal_axis] - span[0, normal_axis]) < 1e-9
        assert inward[along_axis] == 0 and abs(inward[normal_axis]) == 1
        if row['side'] == 'defense':
            span = np.array(warp['attackToDefenseSvg']['origin']) - span
            inward = -inward
        mesh_path = Path(row['prefix'] + '-shadow.f32')
        mesh_bytes = mesh_path.read_bytes()
        assert hashlib.sha256(mesh_bytes).hexdigest() == row['meshSha256']
        geometry = PhysicalGeometry(warp, row, np.frombuffer(mesh_bytes, dtype='<f4'))
        for scale in manifest['scales']:
            ink_path = folder / f"{row['side']}-{scale}x-ink.png"
            visibility_path = Path(f"{row['prefix']}-{scale}x-visibility.png")
            unclipped_path = Path(f"{row['prefix']}-{scale}x-unclipped.png")
            ink = np.asarray(Image.open(ink_path).convert('RGBA'))[:, :, 3]
            visibility = np.asarray(Image.open(visibility_path).convert('RGBA'))[:, :, 3]
            unclipped = np.asarray(Image.open(unclipped_path).convert('RGBA'))[:, :, 3]
            assert ink.shape == visibility.shape
            if normal_axis == 0:
                ink, visibility, unclipped = ink.T, visibility.T, unclipped.T
            wall_y = span[0, normal_axis] * scale
            columns = np.arange(int(np.ceil(span[:, along_axis].min() * scale - .5)), int(np.floor(span[:, along_axis].max() * scale - .5)) + 1)
            xy = np.empty((len(columns), 2))
            xy[:, along_axis] = (columns + .5) / scale
            xy[:, normal_axis] = span[0, normal_axis]
            frustum = geometry.in_frustum(xy)
            # A center just inside the FOV can rasterize only a faint sliver.
            # Such a pixel cannot test wall contact. Exclude its physical pixel
            # footprint at the wall; overlapping poses cover these columns.
            pixel_corners = xy[:, None, :] + np.array([[-.5, -.5], [-.5, .5], [.5, -.5], [.5, .5]])[None] / scale
            footprint_inside = geometry.in_frustum(pixel_corners.reshape(-1, 2), margin=False).reshape(-1, 4).all(axis=1)
            footprint_excluded = int((frustum & ~footprint_inside).sum())
            frustum &= footprint_inside
            measured = []
            missing_ink = 0
            for column, point, within in zip(columns, xy, frustum):
                if not within:
                    continue
                ys = np.arange(max(0, int(wall_y - 9 * scale)), min(ink.shape[0], int(wall_y + 9 * scale) + 1))
                gap = pixel_gap(ink[:, column], visibility[:, column], ys, wall_y, inward[normal_axis], scale)
                if gap is not None:
                    normal_distance = ((ys + .5) - wall_y) * inward[normal_axis]
                    beyond = (normal_distance < -1.5 * scale) & (normal_distance >= -3 * scale)
                    measured.append(dict(column=int(column), pointSvg=point.tolist(), **gap,
                                         clippedBeyondWallCoveragePixels=int((visibility[ys[beyond], column] > 0).sum()),
                                         unclippedBeyondWallCoveragePixels=int((unclipped[ys[beyond], column] > 0).sum())))
                else:
                    missing_ink += 1
            offsets = np.arange(-1.5, 5.001, .005)
            sample_xy = xy[:, None] + offsets[None, :, None] * inward
            clear = geometry.clear(sample_xy.reshape(-1, 2)).reshape(len(xy), -1)
            geometric = []
            for point, visible, within in zip(xy, clear, frustum):
                if within and visible.any():
                    first = int(np.flatnonzero(visible)[0])
                    geometric.append(dict(pointSvg=point.tolist(), firstClearInwardSvg=float(offsets[first])))
            gaps = [r['blankPixels'] for r in measured if r['blankPixels'] is not None]
            geometric_offsets = [p['firstClearInwardSvg'] for p in geometric]
            records.append(dict(id=row['id'], side=row['side'], scale=scale, label=fixture['label'],
                expected='cone reaches actual inner wall ink; no fully transparent pixel run',
                svgSpan=span.tolist(), inward=inward.tolist(), alongAxis=along_axis, excludedByRangeOrFov=int((~frustum).sum()),
                additionalPixelFootprintFovExclusions=footprint_excluded,
                measuredProfiles=len(measured), missingConeProfiles=sum(r['blankPixels'] is None for r in measured),
                missingInkProfiles=missing_ink,
                profilesWithBlankPixels=sum(g > 0 for g in gaps), maximumBlankPixels=max(gaps, default=None),
                profilesFailingCoverageContact=sum(not r.get('coverageContactPassed', False) for r in measured),
                maximumHalfCoverageSeparationPixels=max((r['halfCoverageSeparationPixels'] for r in measured if r.get('halfCoverageSeparationPixels') is not None), default=None),
                maximumCoverageDeficitPixels=max((r['coverageDeficitPixels'] for r in measured if r.get('coverageDeficitPixels') is not None), default=None),
                profilesWithDisplayedSpill=sum(r['clippedBeyondWallCoveragePixels'] > 0 for r in measured),
                profilesWithUnclippedSpill=sum(r['unclippedBeyondWallCoveragePixels'] > 0 for r in measured),
                medianBlankPixels=float(np.median(gaps)) if gaps else None,
                geometricFirstClearInwardSvgRange=[min((p['firstClearInwardSvg'] for p in geometric), default=None), max((p['firstClearInwardSvg'] for p in geometric), default=None)],
                requiresSeparateWallPlacementReview=bool(not geometric_offsets or max(abs(value) for value in geometric_offsets) > .01),
                geometricSamplingStepSvg=.005, profiles=measured, geometricProfiles=geometric,
                inkSha256=hashlib.sha256(ink_path.read_bytes()).hexdigest(), visibilitySha256=hashlib.sha256(visibility_path.read_bytes()).hexdigest(),
                unclippedSha256=hashlib.sha256(unclipped_path.read_bytes()).hexdigest()))
            if row['id'] == 'annotated-clove':
                # Gap between the authored left lip ending x222.445 and right
                # lip starting x236.012. Test both sides of the opening plane.
                points = np.array([[x, y] for x in (225., 229., 233.) for y in (209.5, 213.5)])
                if row['side'] == 'defense':
                    points = np.array(warp['attackToDefenseSvg']['origin']) - points
                pixels = np.floor(points * scale).astype(int)
                values = visibility[pixels[:, 1], pixels[:, 0]]
                openings.append(dict(id='clove-throat-preserved', side=row['side'], scale=scale,
                                     pointsSvg=points.tolist(), alpha=values.tolist(),
                                     allVisible=bool((values >= 128).all()), physicalShadowClear=geometry.clear(points).tolist()))
    report = dict(scope=__doc__, manifestSha256=hashlib.sha256(manifest_bytes).hexdigest(),
                  reviewedFixtures=fixtures if fixtures is not None else SOLID_SPANS,
                  reviewedFixturesSha256=hashlib.sha256(json.dumps(fixtures if fixtures is not None else SOLID_SPANS, sort_keys=True).encode()).hexdigest(),
                  pixelPolicy='Zero-coverage blank runs plus separation of >=128/255 coverage bodies. At most one intervening raster pixel with <=0.5+2/255 total uncovered area is allowed. Summed ink+cone coverage is an area diagnostic, not alpha-over compositing. Range/FOV edges excluded; no dilation or wall inference from color.',
                  limitation='Passing pixel contact is necessary but does not prove exact wall placement or a straight stopping edge. Independently sampled shadow-mesh offsets remain explicit; source-level structural and corner verification is separate.',
                  rasterProfiles=records, preservedOpenings=openings)
    (folder / 'contact-report.json').write_text(json.dumps(report, indent=2) + '\n')
    for row in records:
        print(row['id'], row['side'], row['scale'], 'max/median blank px', row['maximumBlankPixels'], row['medianBlankPixels'],
              '50% separation/deficit', row['maximumHalfCoverageSeparationPixels'], row['maximumCoverageDeficitPixels'],
              'geometrySVG', row['geometricFirstClearInwardSvgRange'])
    print('opening checks', [(o['side'], o['scale'], o['allVisible']) for o in openings])
    return all(r['measuredProfiles'] and not r['missingInkProfiles'] and not r['missingConeProfiles'] and r['maximumBlankPixels'] == 0 and not r['profilesFailingCoverageContact'] and not r['profilesWithDisplayedSpill'] for r in records) and all(o['allVisible'] for o in openings)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('folder', type=Path)
    parser.add_argument('--fixtures', type=Path, help='JSON list of explicitly reviewed axis-aligned spans.')
    parser.add_argument('--require-contact', action='store_true', help='Fail after writing evidence if a solid span has a blank pixel band/spill or an opening closes.')
    args = parser.parse_args()
    passed = run(args.folder, json.loads(args.fixtures.read_text()) if args.fixtures else None)
    if args.require_contact and not passed:
        raise SystemExit('Wall contact regression failed; see contact-report.json')

"""Measure bounded moving cones, including source fallback and sampled error.

Section endpoints seed an adaptive radial mesh. Floor-state transition angles
are not exhaustively compiled here; validation can expose missed intervals but
cannot certify their absence. This is not the production cone algorithm.
"""
import argparse
import hashlib
import json
import math
from pathlib import Path
import time
import numpy as np

from probe_source_floor_regressions import load_support, source_model
from verify_native_floor_atlas import NativeAtlas


def radial_chord(left_angle, left_range, right_angle, right_range, angle):
    a = left_range * np.array([math.cos(left_angle), math.sin(left_angle)])
    b = right_range * np.array([math.cos(right_angle), math.sin(right_angle)])
    direction = np.array([math.cos(angle), math.sin(angle)])
    edge = b - a
    determinant = direction[0] * edge[1] - direction[1] * edge[0]
    if abs(determinant) < 1e-15:
        return (left_range + right_range) / 2
    return float((a[0] * edge[1] - a[1] * edge[0]) / determinant)


def build_cone(cast, angles, tolerance, maximum_queries):
    cache = {}
    limited = False
    def query(angle):
        if angle not in cache:
            cache[angle] = cast(angle)
        return cache[angle]
    def refine(left, right, depth):
        nonlocal limited
        a, b = query(left), query(right)
        probes = [left + (right - left) * q for q in (.25, .5, .75)]
        if len(cache) + 3 > maximum_queries:
            limited = True
            return [left, right]
        error = max(abs(query(t) - radial_chord(left, a, right, b, t)) for t in probes)
        if error <= tolerance or right - left < 1e-9:
            return [left, right]
        if depth >= 24:
            limited = True
            return [left, right]
        middle = probes[1]
        return refine(left, middle, depth + 1)[:-1] + refine(middle, right, depth + 1)
    output = []
    for left, right in zip(angles[:-1], angles[1:]):
        output.extend(refine(float(left), float(right), 0)[:-1])
    output.append(float(angles[-1]))
    return np.array(output), np.array([query(t) for t in output]), cache, limited


def seed_angles(arrays, origin, heading, aperture, distance, include_sections):
    left, right = heading - aperture / 2, heading + aperture / 2
    angles = list(np.linspace(left, right, 9))
    if include_sections:
        points = arrays['segments'].reshape(-1, 2) - origin[:2]
        points = points[(np.linalg.norm(points, axis=1) <= distance) & (np.linalg.norm(points, axis=1) > 1e-8)]
        values = heading + (np.arctan2(points[:, 1], points[:, 0]) - heading + math.pi) % (2 * math.pi) - math.pi
        for value in values:
            for offset in (-1e-7, 0., 1e-7):
                if left < value + offset < right:
                    angles.append(float(value + offset))
    return np.unique(angles)


def run(revision, frames, validation_rays, tolerance, maximum_queries, include_sections, output_name='moving-floor-cone-probe-v1'):
    source = source_model(revision, 'split', True)
    support = load_support(revision, 'split', True)
    atlases = {enabled: NativeAtlas(revision, source=source, transit=enabled) for enabled in (False, True)}
    center = np.array([20.599371111492427, 39.59257844288108, 6.781631480113873])
    aperture, distance = math.pi / 2, 5.
    output = revision / output_name
    output.mkdir(exist_ok=True)
    records, pictures = [], []
    for frame in range(frames):
        phase = frame * 2 * math.pi / frames
        origin = center + [.08 * math.cos(phase), .08 * math.sin(phase), 0]
        heading = phase
        angles = seed_angles(atlases[False].arrays, origin, heading, aperture, distance, include_sections)
        row = dict(frame=frame, origin=origin.tolist(), headingRadians=heading, seedAngles=len(angles), variants=[])
        cache_by_variant = {}
        # Alternate order; this is still a Python diagnostic, not a quiet AOT benchmark.
        for enabled in ((False, True) if frame % 2 == 0 else (True, False)):
            atlas = atlases[enabled]
            timings, native, fallbacks, pieces = [], [], [], []
            def cast(angle):
                start = time.perf_counter()
                result = atlas.cast(source, origin, [math.cos(angle), math.sin(angle)], distance)
                timings.append(time.perf_counter() - start)
                native.append(result['nativeSeconds'])
                fallbacks.append(result['fallbacks'])
                pieces.append(len(result['rows']))
                return result['distanceMeters']
            start = time.perf_counter()
            mesh_angles, mesh_ranges, cache, limited = build_cone(cast, angles, tolerance, maximum_queries)
            build_seconds = time.perf_counter() - start
            cache_by_variant[enabled] = cache
            # New angle locations are not part of the adaptive construction.
            probe_angles = heading - aperture / 2 + (np.arange(validation_rays) + .38196601125) / validation_rays * aperture
            errors, source_errors = [], []
            for index, angle in enumerate(probe_angles):
                segment = min(int(np.searchsorted(mesh_angles, angle) - 1), len(mesh_angles) - 2)
                predicted = radial_chord(mesh_angles[segment], mesh_ranges[segment], mesh_angles[segment+1], mesh_ranges[segment+1], angle)
                actual = atlas.cast(source, origin, [math.cos(angle), math.sin(angle)], distance)
                errors.append(abs(predicted - actual['distanceMeters']))
                if index % max(1, validation_rays // 8) == 0:
                    expected = support.cast(source, origin, [math.cos(angle), math.sin(angle)], distance, True, True, True, .35, True)
                    source_errors.append(abs(expected['distanceMeters'] - actual['distanceMeters']))
            vertices = origin[:2] + mesh_ranges[:, None] * np.c_[np.cos(mesh_angles), np.sin(mesh_angles)]
            triangles = np.array([[origin[:2], a, b] for a, b in zip(vertices[:-1], vertices[1:])])
            variant = dict(transit=enabled, queryCount=len(cache), meshTriangles=len(triangles), queryBudgetReached=limited,
                           buildMilliseconds=build_seconds*1000, nativeMilliseconds=sum(native)*1000,
                           queryWithFallbackMilliseconds=sum(timings)*1000, sourceFallbackCalls=sum(fallbacks),
                           meanPieces=float(np.mean(pieces)), maximumSampledMeshErrorMeters=max(errors),
                           samplesAboveTolerance=sum(e > tolerance for e in errors), sourceCheckRays=len(source_errors),
                           maximumSourceCheckErrorMeters=max(source_errors), mesh=triangles.tolist())
            row['variants'].append(variant)
            if enabled:
                pictures.append((frame, origin, vertices, variant))
        common = set(cache_by_variant[False]) & set(cache_by_variant[True])
        row['commonQueryAngles'] = len(common)
        row['maximumTransitDistanceDifferenceMeters'] = max(abs(cache_by_variant[False][a] - cache_by_variant[True][a]) for a in common)
        records.append(row)
        print(frame, [(v['transit'], v['queryCount'], round(v['buildMilliseconds'], 2), v['samplesAboveTolerance']) for v in row['variants']], flush=True)
    report = dict(scope=__doc__, frames=frames, distanceMeters=distance, apertureRadians=aperture,
                  toleranceMeters=tolerance, validationRaysPerCone=validation_rays, sectionEndpointSeeds=include_sections,
                  sourceSha256=hashlib.sha256((revision/'full-height-input-v1/split/split.height.bin.gz').read_bytes()).hexdigest(),
                  atlasSha256=hashlib.sha256((revision/'local-floor-atlas-v1/split.npz').read_bytes()).hexdigest(),
                  transitAtlasSha256=hashlib.sha256((revision/'local-floor-atlas-v1/split-with-transit.npz').read_bytes()).hexdigest(),
                  nativeSha256=hashlib.sha256((revision/'native-tactical-rays-build/Release/tactical_floor_atlas.dll').read_bytes()).hexdigest(),
                  records=records, productionAcceptance=False,
                  limitations=['Adaptive probes and section endpoint seeds do not enumerate every floor-state transition angle.',
                               'Timing includes Python dispatch and original-source fallbacks. This is not full-app FPS or final all-map data.',
                               'Nearby moving origins and five-meter range only; current bounded atlas floor roles remain provisional.'])
    (output/'split.json').write_text(json.dumps(report, indent=2)+'\n')
    import matplotlib
    matplotlib.use('Agg')
    import matplotlib.pyplot as plt
    columns = 4
    fig, axes = plt.subplots(math.ceil(frames/columns), columns, figsize=(16, 4*math.ceil(frames/columns)), squeeze=False)
    for ax, (frame, origin, vertices, variant) in zip(axes.ravel(), pictures):
        ax.fill(*np.vstack([origin[:2], vertices, origin[:2]]).T, color='#12a594', alpha=.5)
        for line in atlases[False].arrays['segments']:
            ax.plot(*line.T, color='#674422', linewidth=.3)
        ax.scatter(*origin[:2], color='black', s=9)
        ax.set_xlim(center[0]-6, center[0]+6); ax.set_ylim(center[1]-6, center[1]+6); ax.set_aspect('equal')
        ax.set_title(f"Frame {frame}: {variant['queryCount']} queries, {variant['buildMilliseconds']:.1f} ms\nSampled error {variant['maximumSampledMeshErrorMeters']:.4f} m", fontsize=9)
    for ax in axes.ravel()[len(pictures):]: ax.axis('off')
    fig.suptitle('Bounded compact-cone diagnostic | source XY | provisional floor | sampled angular validation')
    fig.tight_layout(); fig.savefig(output/'split.png', dpi=130); plt.close(fig)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('revision', type=Path)
    parser.add_argument('--frames', type=int, default=8)
    parser.add_argument('--validation-rays', type=int, default=128)
    parser.add_argument('--tolerance', type=float, default=.01)
    parser.add_argument('--maximum-queries', type=int, default=4096)
    parser.add_argument('--regular-seeds-only', action='store_true')
    parser.add_argument('--output-name', default='moving-floor-cone-probe-v1')
    args = parser.parse_args()
    run(args.revision, args.frames, args.validation_rays, args.tolerance, args.maximum_queries, not args.regular_seeds_only, args.output_name)

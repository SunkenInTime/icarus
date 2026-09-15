"""Verify frozen masked triangles can become opaque 2D section intervals.

Tests isolated source faces, not nearest hits through a whole map or gameplay.
UVs/materials/textures come from the frozen full-height pack. The reference
intersects the original 3D triangle and evaluates its alpha at each ray hit.
"""
import argparse
import hashlib
import io
import json
from pathlib import Path
import numpy as np
from audit_tactical_target_rays import ReferenceModel
from static_alpha_sections import opaque_intervals
from world_visibility_ray_reference import ray_triangle, sample_alpha


def run(revision, name, limit):
    path = revision / 'full-height-input-v1' / name / f'{name}.height.bin.gz'
    source = ReferenceModel(path)
    arrays = source.arrays
    ids = np.flatnonzero(arrays['faceMasks'] >= 0)
    rng = np.random.default_rng(923217)
    rng.shuffle(ids)
    records, stored, failures = [], [], []
    tested = opaque = transparent = threshold_guards = 0
    for face_id in ids:
        triangle = arrays['vertices'][arrays['faces'][face_id]].astype(float)
        slope = rng.uniform(-.4, .4, 2)
        center = triangle.mean(0)
        plane = np.r_[slope, center[2] - slope @ center[:2]]
        values = triangle[:, 2] - triangle[:, :2] @ plane[:2] - plane[2]
        cuts = []
        for i in range(3):
            j = (i + 1) % 3
            if (values[i] <= 0) != (values[j] <= 0):
                t = -values[i] / (values[j] - values[i])
                cuts.append(triangle[i] + t * (triangle[j] - triangle[i]))
        if len(cuts) != 2:
            continue
        cuts = np.array(cuts)
        direction = cuts[1, :2] - cuts[0, :2]
        length = np.linalg.norm(direction)
        if length < 1e-6:
            continue
        mask = arrays['faceMasks'][face_id]
        policy = source.materials[int(arrays['maskedMaterials'][mask])]
        texture = source.textures[policy['texture']]
        # Affine UV interpolation in the original triangle, including vertical
        # faces whose XY projection is singular.
        barycentric = np.linalg.lstsq(np.vstack([triangle.T, np.ones(3)]),
                                     np.c_[cuts, np.ones(2)].T, rcond=None)[0].T
        uvs = barycentric @ arrays['maskedUvs'][mask]
        intervals = opaque_intervals(texture, *uvs, policy)
        segments = cuts[0, :2] + intervals[:, :, None] * direction
        stored.extend(segments)
        normal_xy = np.array([-direction[1], direction[0]]) / length
        samples = list(rng.uniform(1e-6, 1 - 1e-6, 128))
        for boundary in intervals.ravel():
            samples.extend(t for t in (boundary - 1e-7, boundary + 1e-7) if 0 < t < 1)
        for t in samples:
            xy = cuts[0, :2] + t * direction
            endpoints = np.array([xy - normal_xy * .01, xy + normal_xy * .01])
            xyz = np.c_[endpoints, endpoints @ plane[:2] + plane[2]]
            ray = xyz[1] - xyz[0]
            hit = ray_triangle(xyz[0], ray / np.linalg.norm(ray), triangle)
            if hit is None:
                failures.append(dict(face=int(face_id), t=t, reason='reference missed interior face'))
                continue
            uv = np.array(hit[1]) @ arrays['maskedUvs'][mask]
            alpha = sample_alpha(texture, uv, policy)
            # Floating point classification exactly at a threshold is outside
            # this numerical check. Record rather than silently count it.
            if abs(alpha - policy['threshold']) < 1e-10:
                threshold_guards += 1
                continue
            expected = alpha >= policy['threshold']
            actual = bool(np.any((intervals[:, 0] <= t) & (intervals[:, 1] >= t)))
            tested += 1
            opaque += expected
            transparent += not expected
            if expected != actual:
                failures.append(dict(face=int(face_id), t=t, alpha=alpha, expected=bool(expected)))
        records.append(dict(face=int(face_id), material=int(arrays['maskedMaterials'][mask]),
                            segmentLengthMeters=float(length), opaqueIntervals=len(intervals)))
        if len(records) >= limit:
            break
    output = revision / 'static-alpha-sections-v1'
    output.mkdir(exist_ok=True)
    payload = io.BytesIO()
    np.savez_compressed(payload, segments=np.array(stored, dtype=float).reshape(-1, 2, 2))
    (output / f'{name}.segments.npz').write_bytes(payload.getvalue())
    report = dict(map=name, scope=__doc__, sourceSha256=hashlib.sha256(path.read_bytes()).hexdigest(),
                  sourceMaskedFaces=len(ids), testedFaces=len(records), testedRays=tested,
                  opaqueRays=int(opaque), transparentRays=int(transparent),
                  numericalThresholdGuards=threshold_guards, opaqueSegments=len(stored),
                  compressedSegmentBytes=len(payload.getvalue()), records=records, failures=failures,
                  limitation='Isolated-face alpha proof. No whole-map size, floor selection, runtime, animated shader, or culling certification. Zero-length threshold contacts are not stored as wall segments.')
    (output / f'{name}.json').write_text(json.dumps(report, indent=2) + '\n')
    print(name, len(records), 'faces', tested, 'rays', len(stored), 'segments', len(failures), 'failures', flush=True)
    if failures:
        raise AssertionError('Static alpha intervals disagree with original source faces')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--revision', type=Path, required=True)
    parser.add_argument('--map', default='split')
    parser.add_argument('--faces', type=int, default=128)
    args = parser.parse_args()
    names = sorted(p.name for p in (args.revision / 'full-height-input-v1').iterdir() if p.is_dir()) if args.map == 'all' else [args.map]
    for name in names:
        run(args.revision, name, args.faces)

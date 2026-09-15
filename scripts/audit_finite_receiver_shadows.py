"""Compare finite receiver shadows with independent original-height rays."""
import argparse
import hashlib
import io
import json
from pathlib import Path
import time

import numpy as np
import shapely

from experimental_floor_relative_visibility import FloorPatch, first_hit, rectangle, surface, wall
from finite_receiver_shadows import Receiver, build_shadows, renderer_mesh_checked


def checked_mesh(eye, rows):
    mesh, fallback = renderer_mesh_checked(eye, rows)
    assert not fallback, fallback
    return mesh


def scenes():
    ramp = FloorPatch(rectangle(0, 5), np.array([-.8, 0., 4.]))
    lower = FloorPatch(rectangle(5, 20), np.array([0., 0., 0.]))
    flat = FloorPatch(rectangle(0, 20), np.array([0., 0., 0.]))
    up = FloorPatch(rectangle(0, 5), np.array([.8, 0., 0.]))
    down = FloorPatch(rectangle(5, 10), np.array([-.8, 0., 8.]))
    return [
        ('descending-ramp-near-hidden-far-visible', [1, 0, 4.95],
         np.concatenate([surface(ramp), surface(lower), wall(7, 0, 2.5)]),
         [Receiver(ramp.polygon, ramp.plane), Receiver(lower.polygon, lower.plane)]),
        ('same-level-tall-wall-and-no-wall-piercing', [1, 0, 1.75],
         np.concatenate([surface(flat), wall(7, 0, 3)]), [Receiver(flat.polygon, flat.plane)]),
        ('same-level-low-cover-and-overhead-roof-clear', [1, 0, 1.75],
         np.concatenate([surface(flat), surface(flat, 3), wall(7, 0, 1.2)]),
         [Receiver(flat.polygon, flat.plane)]),
        ('crest-ground-must-occlude', [1, 0, 2.55],
         np.concatenate([surface(up), surface(down)]),
         [Receiver(up.polygon, up.plane), Receiver(down.polygon, down.plane)]),
    ]


def shadow_geometry(rows, receiver_id):
    polygons = [shapely.Polygon(row['polygon']) for row in rows if row['receiver'] == receiver_id]
    return shapely.union_all(polygons) if polygons else shapely.Polygon()


def verify_scene(name, eye, geometry, receivers):
    rows, unresolved = build_shadows(eye, geometry, receivers)
    assert not unresolved, (name, unresolved)
    count, differences, blocked, float32_differences = 0, 0, 0, 0
    for index, receiver in enumerate(receivers):
        low, high = receiver.footprint.min(0), receiver.footprint.max(0)
        # Non-boundary fixed samples. Source triangle ray checks are validation,
        # not part of the candidate's polygon-building algorithm.
        xs = np.linspace(low[0] + .0137, high[0] - .0173, 113)
        ys = np.linspace(low[1] + .0191, high[1] - .0119, 37)
        xy = np.array(np.meshgrid(xs, ys)).reshape(2, -1).T
        points = receiver.lift(xy)
        expected = np.array([first_hit(geometry, eye, point) is not None for point in points])
        observed = shapely.covers(shadow_geometry(rows, index), shapely.points(xy))
        mesh = checked_mesh(eye, [row for row in rows if row['receiver'] == index])
        mesh_world = mesh.astype(float) + np.asarray(eye[:2])
        mesh_shape = shapely.union_all(shapely.polygons(mesh_world)) if len(mesh_world) else shapely.Polygon()
        mesh_observed = shapely.covers(mesh_shape, shapely.points(xy))
        float32_differences += int(np.count_nonzero(expected != mesh_observed))
        differences += int(np.count_nonzero(expected != observed))
        blocked += int(expected.sum())
        count += len(xy)
    assert differences == 0, (name, differences)
    assert float32_differences == 0, (name, float32_differences)
    return dict(name=name, queries=count, blocked=blocked, differences=differences,
                float32RendererContractDifferences=float32_differences,
                receiverCount=len(receivers), sourceTriangleCount=len(geometry),
                shadowPolygons=len(rows), rendererTriangles=len(checked_mesh(eye, rows))), rows


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('output', type=Path)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    results = []
    cases = scenes()
    for case in cases:
        result, rows = verify_scene(*case)
        results.append(result)
        if case[0].startswith('descending'):
            lower_shadow = shadow_geometry(rows, 1)
            assert bool(shapely.covers(lower_shadow, shapely.Point(8, 0)))
            assert not bool(shapely.covers(lower_shadow, shapely.Point(12, 0)))
            end = 1 + 6 * (4.95 - 1.75) / (4.95 - 2.5)
            line = shapely.intersection(lower_shadow, shapely.LineString([[5, 0], [20, 0]]))
            np.testing.assert_allclose(np.array(line.bounds)[[0, 2]], [7, end], atol=1e-12)
            np.savez_compressed(args.output / 'synthetic-shadow-contract.npz',
                                originalTriangles=case[2], observer=np.array(case[1]),
                                shadowTrianglesRelativeXY=checked_mesh(case[1], rows),
                                receiverFloorPlanes=np.array([r.floor_plane for r in case[3]]),
                                receiverFootprints=np.array([r.footprint for r in case[3]]))
        if case[0].startswith('same-level-tall'):
            shadow = shadow_geometry(rows, 0)
            assert not shapely.covers(shadow, shapely.Point(4, 0)), 'blocker behind target must not occlude'
            assert shapely.covers(shadow, shapely.Point(8, 0)), 'tall wall must remain opaque'
        if case[0].startswith('crest'):
            assert shapely.covers(shadow_geometry(rows, 1), shapely.Point(9, 0)), 'ground crest must remain opaque'
        # Frozen source policy is two-sided; reversed source winding must agree.
        reverse, pending = build_shadows(case[1], case[2][:, ::-1], case[3])
        assert not pending
        for index in range(len(case[3])):
            assert shapely.symmetric_difference(shadow_geometry(rows, index), shadow_geometry(reverse, index)).area < 1e-10
    # Eye parallel to the receiver plane is already covered by same-level cases.
    # Exactly coplanar with a blocker has zero-area/event semantics, so it is
    # explicitly deferred instead of manufacturing a clear polygon result.
    coplanar = np.array([[[3, -1, 1.75], [4, -1, 1.75], [3, 1, 1.75]]])
    _, unresolved = build_shadows([1, 0, 1.75], coplanar, [cases[1][3][0]])
    assert len(unresolved) == 1 and 'coplanar' in unresolved[0]['reason']

    # Python CPU timings only: this is not a Flutter/native/GPU refresh test.
    _, eye, geometry, receivers = cases[0]
    origins = [np.array(eye) + [i * .003, i * .004, 0.] for i in range(10)]
    for _ in range(10):
        for origin in origins:
            build_shadows(origin, geometry, receivers)
    timings = []
    for _ in range(60):
        begin = time.perf_counter()
        for origin in origins:
            build_shadows(origin, geometry, receivers)
        timings.append((time.perf_counter() - begin) * 1000)
    # Concrete compact profile example: one vertical opaque wall as XY endpoints
    # plus bottom/top Z. Floors remain receiver planes and source floor faces.
    profile = np.array([[7., -2., 7., 2., 0., 2.5]], dtype=np.float64)
    floors = geometry[:4]
    raw = profile.nbytes + floors.nbytes + sum(r.floor_plane.nbytes + r.footprint.nbytes for r in receivers)
    stream = io.BytesIO()
    np.savez_compressed(stream, wallProfiles=profile, floorTriangles=floors,
                        receiverFloorPlanes=np.array([r.floor_plane for r in receivers]),
                        receiverFootprints=np.array([r.footprint for r in receivers]))
    source = Path(__file__).resolve().parent
    report = dict(status='bounded-offline-prototype-pass-not-production', scenes=results,
                  totalIndependentRays=sum(r['queries'] for r in results),
                  finiteShadowAtCenter=[7., end], coplanarExplicitFallback=unresolved,
                  pythonTenObserverBatchMilliseconds={key: float(np.quantile(timings, quantile))
                    for key, quantile in [('p50', .5), ('p95', .95), ('p99', .99)]},
                  benchmark=dict(warmupBatches=10, measuredBatches=60, observersPerBatch=10,
                                 trianglesPerScene=len(geometry), receiverPlanes=len(receivers),
                                 quietHardwareBaseline=False, unit='Python CPU milliseconds'),
                  compactSyntheticStaticBytes=raw, compressedNpzBytes=len(stream.getvalue()),
                  limitations=[
                      'Opaque triangles only. Material masks, doors and state are not implemented.',
                      'Opaque profiles use two-sided source blocking; actual game culling is not certified.',
                      'Convex receiver footprints and finite doubles; not an exact-arithmetic or all-contact proof.',
                      'Zero-area and coplanar contacts explicitly require a separate source fallback.',
                      'Target-floor selection and stacked-layer choice are inputs, not solved here.',
                      'Mesh preserves source XY relative to observer; existing renderer retains range/FOV, SVG mask and display W.',
                      'No whole-map size or high-refresh prediction can be inferred from this synthetic CPU benchmark.',
                      'No application or production policy change and no live-game validation.',
                  ],
                  sourceSha256={name: hashlib.sha256((source / name).read_bytes()).hexdigest()
                      for name in ['finite_receiver_shadows.py', 'audit_finite_receiver_shadows.py',
                                   'experimental_floor_relative_visibility.py']})
    (args.output / 'report.json').write_text(json.dumps(report, indent=2) + '\n')
    import matplotlib
    matplotlib.use('Agg')
    import matplotlib.pyplot as plt
    from matplotlib.patches import Polygon
    _, observer, triangles, receivers = cases[0]
    rows, _ = build_shadows(observer, triangles, receivers)
    figure, axis = plt.subplots(figsize=(10, 3.5))
    for row in rows:
        axis.add_patch(Polygon(row['polygon'], facecolor='#d66464', alpha=.4, edgecolor='#ad3232'))
    axis.plot([0, 20, 20, 0, 0], [-2, -2, 2, 2, -2], color='#555555')
    axis.plot([5, 5], [-2, 2], '--', color='#888888', label='Ramp / lower-floor seam')
    axis.plot([7, 7], [-2, 2], color='#111111', lw=4, label='2.5 m wall')
    axis.scatter([1, 8, 12], [0, 0, 0], color=['#111111', '#ad3232', '#167650'], zorder=5)
    for x, label in [(1, 'Eye above ramp'), (8, 'Near head hidden'), (12, 'Far head visible')]:
        axis.annotate(label, (x, 0), xytext=(0, 17), textcoords='offset points', ha='center', fontsize=9)
    axis.set_xlim(0, 14)
    axis.set_ylim(-2.6, 2.7)
    axis.set_aspect('equal')
    axis.set_xlabel('Original source X (m)')
    axis.set_ylabel('Original source Y (m)')
    axis.set_title('Finite standing-target shadows; center shadow ends at X=8.836735 m')
    axis.legend(loc='lower right', fontsize=8)
    figure.text(.01, .01, 'Synthetic opaque-profile prototype. Existing SVG receiver mask/display W would be applied afterward.', fontsize=8)
    figure.tight_layout(rect=[0, .04, 1, 1])
    figure.savefig(args.output / 'finite-shadow-plan.png', dpi=150)
    plt.close(figure)
    print(json.dumps({key: report[key] for key in ['status', 'totalIndependentRays',
                     'pythonTenObserverBatchMilliseconds', 'compactSyntheticStaticBytes', 'compressedNpzBytes']}))


if __name__ == '__main__':
    main()

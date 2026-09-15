"""Deterministic distinction between floor flattening and standing-target LOS.

Offline analytic regression only. No game measurements, application queries,
production assets, or floor policy are changed by this tool.
"""
import argparse
import hashlib
import json
from pathlib import Path

import numpy as np

from experimental_floor_relative_visibility import (
    FloorPatch, first_hit, flatten_triangles, rectangle, surface, wall,
)


def hit_record(hit):
    if hit is None:
        return None
    return dict(segmentFraction=hit[0], triangleIndex=hit[1])


def probe():
    eye = 1.75
    ramp = FloorPatch(rectangle(0, 5), np.array([-.8, 0., 4.]))
    lower = FloorPatch(rectangle(5, 20), np.array([0., 0., 0.]))
    original = np.concatenate([surface(ramp), surface(lower), wall(7, 0, 2.5)])
    flat, _, _ = flatten_triangles(original, [ramp, lower])
    observer = np.array([1., 0., ramp.height([1, 0]) + eye])
    rows = []
    for target_x in [8., 12.]:
        target_head = np.array([target_x, 0., eye])
        target_floor = np.array([target_x, 0., 0.])
        head_z_at_wall = observer[2] + (eye - observer[2]) * 6 / (target_x - 1)
        floor_z_at_wall = observer[2] * (1 - 6 / (target_x - 1))
        head_hit = first_hit(original, observer, target_head)
        floor_hit = first_hit(original, observer, target_floor)
        flattened_hit = first_hit(flat, [1., 0., eye], [target_x, 0., eye])
        # The analytic plane-crossing oracle is independent of triangle casting.
        assert (head_hit is None) == (head_z_at_wall > 2.5)
        assert (floor_hit is None) == (floor_z_at_wall > 2.5)
        assert flattened_hit is not None
        rows.append(dict(targetHead=target_head.tolist(), targetFloor=target_floor.tolist(),
                         headRayHeightAtWall=head_z_at_wall,
                         floorRayHeightAtWall=floor_z_at_wall,
                         originalHeadVisible=head_hit is None,
                         originalFloorVisible=floor_hit is None,
                         currentFlattenedVisible=flattened_hit is None,
                         originalHeadHit=hit_record(head_hit),
                         currentFlattenedHit=hit_record(flattened_hit)))
    assert rows[0]['originalHeadVisible'] is False
    assert rows[1]['originalHeadVisible'] is True
    assert rows[1]['originalFloorVisible'] is False
    shadow_end = observer[0] + (7 - observer[0]) * (observer[2] - eye) / (observer[2] - 2.5)

    # Distinct failure: one affine ramp is exactly representable by flattening,
    # but substituting the wrong ground field makes its ceiling block the ray.
    single_ramp = FloorPatch(rectangle(0, 10), np.array([-.4, 0., 4.]))
    corridor = np.concatenate([surface(single_ramp), surface(single_ramp, 3.)])
    start = np.array([1., 0., 5.35])
    end = np.array([9., 0., 2.15])
    correct, _, _ = flatten_triangles(corridor, [single_ramp])
    wrong_field = FloorPatch(rectangle(0, 10), np.array([0., 0., 3.6]))
    wrong, _, _ = flatten_triangles(corridor, [wrong_field])
    assert first_hit(corridor, start, end) is None
    assert first_hit(correct, [1, 0, eye], [9, 0, eye]) is None
    wrong_hit = first_hit(wrong, [1, 0, eye], [9, 0, eye])
    assert wrong_hit is not None

    # An ordinary tall structural wall must remain opaque on a flat floor.
    tall = wall(7, 0, 3.)
    assert first_hit(tall, [1, 0, eye], [12, 0, eye]) is not None
    return dict(
        status='offline-analytic-policy-regression-pass-not-gameplay-certification',
        units='meters', standingEyeHeight=eye, observer=observer.tolist(),
        ground=[dict(x=[0, 5], plane=ramp.plane.tolist()),
                dict(x=[5, 20], plane=lower.plane.tolist())],
        wall=dict(x=7, y=[-2, 2], z=[0, 2.5]), rows=rows,
        exactLowerStandingShadowInterval=[7., float(shadow_end)],
        wrongGroundFieldControl=dict(originalAndCorrectFieldClear=True,
                                     wrongFieldHit=hit_record(wrong_hit)),
        conclusion=(
            'The current constant relative-Z section hides both lower-floor targets. '
            'Original straight eye-to-standing-head rays hide the near target and see '
            'the farther target; eye-to-floor hides that farther location. Thus a single '
            'first-stop distance per angle cannot encode target-height visibility. '
            'This remains a policy difference even with the correct ground field. '
            'A separate ceiling control demonstrates wrong-ground-field false occlusion.'),
        limitations=[
            'Uses the production policy equation with an independent triangle caster, not the production DLL.',
            'Synthetic physical dimensions are deliberate controls, not a measured Valorant scene.',
            'Standing head-point visibility differs from visibility of any part of a player capsule.',
            'Flattening an entire ramp route is an intentional tactical abstraction and is not always eye-to-eye LOS.',
        ])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('output', type=Path)
    args = parser.parse_args()
    repo = Path(__file__).resolve().parents[1]
    paths = [
        'scripts/audit_standing_target_floor_policy.py',
        'scripts/experimental_floor_relative_visibility.py',
        'lib/widgets/draggable_widgets/utilities/height_view_cone.dart',
        'lib/view_cone/tactical_ground_field.dart',
        'native/height/query_model.hpp', 'native/height/height_pipeline.hpp',
        'scripts/probe_source_floor_support.py',
        'scripts/native_tactical_rays/floor_cone.cpp',
    ]
    result = probe()
    result['sourceSha256'] = {name: hashlib.sha256((repo / name).read_bytes()).hexdigest()
                            for name in paths}
    args.output.mkdir(parents=True, exist_ok=True)
    (args.output / 'report.json').write_text(json.dumps(result, indent=2) + '\n')
    import matplotlib
    matplotlib.use('Agg')
    import matplotlib.pyplot as plt
    figure, axes = plt.subplots(2, 1, figsize=(11, 7), sharex=True)
    upper, flattened = axes
    upper.plot([0, 5, 14], [4, 0, 0], color='#687582', lw=3, label='Actual floor')
    upper.plot([7, 7], [0, 2.5], color='#171c22', lw=7, label='2.5 m wall')
    observer = result['observer']
    upper.scatter([observer[0]], [observer[2]], color='#111111', zorder=5)
    for row, color, label in [(result['rows'][0], '#be3838', 'Near head: hidden'),
                              (result['rows'][1], '#138458', 'Far head: visible')]:
        target = row['targetHead']
        upper.plot([observer[0], target[0]], [observer[2], target[2]], color=color, label=label)
        upper.scatter([target[0]], [target[2]], color=color, zorder=5)
    upper.plot([observer[0], 12], [observer[2], 0], '--', color='#ad7d22', label='Far floor: hidden')
    upper.set_title('Original source heights: looking down at standing targets')
    upper.set_ylabel('Source height (m)')
    upper.legend(loc='upper right', fontsize=9)
    flattened.plot([0, 14], [0, 0], color='#687582', lw=3)
    flattened.plot([7, 7], [0, 2.5], color='#171c22', lw=7)
    flattened.plot([1, 12], [1.75, 1.75], color='#be3838', label='Constant relative height: both hidden')
    flattened.axvspan(7, 14, color='#be3838', alpha=.09)
    flattened.axvspan(7, result['exactLowerStandingShadowInterval'][1], color='#171c22', alpha=.15)
    flattened.set_title('Current floor-normalized policy: one horizontal section, shadow continues to range')
    flattened.set_ylabel('Height above baked floor (m)')
    flattened.set_xlabel('Source X (m)')
    flattened.legend(loc='upper right', fontsize=9)
    for axis in axes:
        axis.set_xlim(0, 14)
        axis.set_ylim(-.3, 5.7)
        axis.grid(alpha=.15)
    figure.text(.01, .005, 'Synthetic policy regression; no live-game claim. Standing height fixed at 1.75 m.', fontsize=9)
    figure.tight_layout(rect=[0, .03, 1, 1])
    figure.savefig(args.output / 'standing-target-regression.png', dpi=140)
    plt.close(figure)
    print(json.dumps(dict(status=result['status'], targets=[
        {key: row[key] for key in ['targetHead', 'originalHeadVisible',
                                  'originalFloorVisible', 'currentFlattenedVisible']}
        for row in result['rows']])))


if __name__ == '__main__':
    main()

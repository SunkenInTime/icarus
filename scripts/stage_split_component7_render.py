"""Source-directed component 7 controls, with explicit provisional height semantics."""
import gzip
import json
from pathlib import Path
import numpy as np
import shapely
from build_split_connected_tower import REV
from build_global_tactical_candidate import GroundField
from tactical_alignment_composite import explicit_warp
from tactical_alignment_receiver import receiver_domain


def main():
    candidate = REV / 'split-wall-family-normalized-candidate-v19'
    summary = json.loads((candidate / 'summary.json').read_text())
    config = json.loads((REV / 'split-wall-family-normalized-candidate-v18/candidate-config.json').read_text())
    item = config['maps']['split']
    item.update(folder=str(candidate / 'native'), candidatePackSha256=summary['packSha256'], scopeLabel='V19 connected component 7; provisional control-relative floor')
    config['scope'] = item['scopeLabel']
    (candidate / 'candidate-config.json').write_text(json.dumps(config, indent=2))
    item.update(automaticQueries=False, queriesById={}, samePhysicalPoseAcrossSides=True)
    region = next(f for f in json.loads((candidate / 'bindings.json').read_text())['families'] if f['edge'] == 200190)
    warp = json.loads(gzip.decompress(Path(item['displayWarpFile']).read_bytes()))
    matrix = np.column_stack((warp['projection']['axisU'], warp['projection']['axisV']))
    offset = np.array(warp['projection']['origin'])
    inverse = np.linalg.inv(matrix)
    source = np.array(warp['sourceNativeMeters']).reshape(-1, 2) @ matrix.T + offset
    target = np.array(warp['targetAttackSvg']).reshape(-1, 2)
    unwarp = explicit_warp(target, source-target, np.array(warp['triangles']).reshape(-1, 3))
    ground = GroundField(Path(item['groundFieldFile']))
    receiver = receiver_domain(Path('assets/maps/split_map.svg'))
    fixture = json.loads((REV / 'gallery-display-all-v1/split-fixtures.json').read_text())
    fixture['cases'] = []
    fixture['policy'] = 'Same physical source poses on both raw SVG sides. Relative-ground diagnostic geometry only; this does not certify original absolute-height corridor preservation or game walkability.'
    spans = region['reviewedAuthoredSpans']
    poses = []
    for index, span in enumerate(spans):
        a, b = np.array(span['startSvg']), np.array(span['endSvg'])
        direction = b-a
        direction /= np.linalg.norm(direction)
        normal = np.array([-direction[1], direction[0]])
        mid = (a+b)/2
        options = [mid+normal*4, mid-normal*4]
        starts = [p for p in options if receiver.covers(shapely.Point(p))]
        assert starts, ('No painted wall origin', span['completeSpan'])
        poses.append((f"wall-{span['completeSpan']}-interior", starts[0], mid, span['completeSpan'], [1.75, 5., 8.25]))
        previous = np.array(spans[index-1]['startSvg'])
        incoming = a-previous
        incoming /= np.linalg.norm(incoming)
        candidates = [a + vector*3 for vector in [normal+np.array([-incoming[1], incoming[0]]), normal-np.array([-incoming[1], incoming[0]]), -normal+np.array([-incoming[1], incoming[0]]), -normal-np.array([-incoming[1], incoming[0]])] if np.linalg.norm(vector) > .1]
        starts = [p for p in candidates if receiver.covers(shapely.Point(p))]
        assert starts, ('No painted corner origin', span['completeSpan'])
        poses.append((f"corner-{span['completeSpan']}-start", starts[0], a, span['completeSpan'], [1.75]))
    for label, start, target, span, heights in poses:
        xy = (unwarp.apply(np.array([start, target]))-offset) @ inverse.T
        direction = xy[1]-xy[0]
        direction /= np.linalg.norm(direction)
        floor = float(ground.heights(xy[:1])[0])
        for eye in heights:
            key = f'{label}-eye-{eye:g}'
            physical = floor+eye
            query = [*xy[0], physical, *direction, 20., float(np.deg2rad(103))]
            fixture['cases'].append(dict(id=key, category='Standing-height diagnostic' if eye == 1.75 else 'Synthetic elevated diagnostic', query=query, originSvg=start.tolist(), sourceDirectedTargetSvg=target.tolist(), eyeHeightMode='absolute', physicalSourceEye=[*xy[0], physical], controlRelativeEyeMeters=eye, sourceGroundAtOriginMeters=floor, completeSpan=span, agentIndex=8))
            item['queriesById'][key] = [*xy[0], eye, *direction, 20., float(np.deg2rad(103))]
    output = REV / 'gallery-component7-v19-fixtures'
    output.mkdir(exist_ok=True)
    (output / 'candidate-config.json').write_text(json.dumps(config, indent=2))
    (output / 'split-fixtures.json').write_text(json.dumps(fixture, indent=2))
    print(output, len(fixture['cases']))


if __name__ == '__main__':
    main()

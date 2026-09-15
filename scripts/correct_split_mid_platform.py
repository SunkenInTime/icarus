"""Classify the authored Mid ramp/platform edge as a tactical floor transition."""
import copy
import json
from pathlib import Path

REV = Path('E:/IcarusWorldAudit/2026-09-06/tactical-visibility-revision')


def main():
    base = REV / 'split-svg-semantic-prototype-v5'
    out = REV / 'split-svg-semantic-prototype-v6'
    out.mkdir(exist_ok=False)
    metadata = json.loads((REV.parent / 'supplemented-v2/world/split/geometry.json').read_text())
    evidence = dict(
        sourceObjects=[dict(index=i, **metadata['objects'][i]) for i in (7432, 7433, 7611)],
        comparison=str(REV / 'mid-platform-edge-source.png'),
        interpretation='The L-shaped SVG component follows the ramp/platform side and end, not a freestanding wall. Treat connected ramp ground as tactically continuous.',
        gameplayReview='Dara marked the platform edge as visible from the Mid box in the defense/top preview. Existing vision-model policy excludes connected ramp elevation edges from occlusion.',
        scope='This component only. Preserve nearby structural walls and all SVG ink.')
    for side, wall_id in [('attack', 'p16-unknown-1'), ('defense', 'p16-unknown-2')]:
        original = json.loads((base / f'split-{side}.json').read_text())
        model = copy.deepcopy(original)
        wall = next(w for w in model['walls'] if w['id'] == wall_id)
        assert wall['unknownHeight']
        wall.update(unknownHeight=False, bands=[], heightModel='connected-ground-transition',
                    heightEvidence=evidence)
        for before, after in zip(original['walls'], model['walls']):
            assert before['rings'] == after['rings']
            if before['id'] != wall_id:
                assert before == after
        assert original['supports'] == model['supports']
        assert original['receiver'] == model['receiver']
        (out / f'split-{side}.json').write_text(json.dumps(model, separators=(',', ':')))
    for name in ['review-poses.json', 'source-height-evidence.json', 'annotation-extension.json']:
        (out / name).write_bytes((base / name).read_bytes())
    (out / 'platform-correction.json').write_text(json.dumps(evidence, indent=2))


if __name__ == '__main__':
    main()

"""Record root's bounded source reviews without promoting offline candidates."""
import hashlib
import json
from pathlib import Path


REV = Path('E:/IcarusWorldAudit/2026-09-06/tactical-visibility-revision')


def evidence(relative):
    path = REV / relative
    return dict(path=relative, sha256=hashlib.sha256(path.read_bytes()).hexdigest())


def main():
    chain = 'split-upper-vent-chain-field-proposal-v2'
    building = 'split-asite-building-connected-proposal-v6'
    contacts = 'split-upper-vent-chain-contacts-native8x-v1'
    members = 'split-upper-vent-chain-source-members-v1'
    reviewed = [*sorted((REV/contacts).glob('*.png')),
                *sorted((REV/members).glob('*.png')),
                *sorted((REV/chain).glob('*six-heights.png')),
                *sorted((REV/building).glob('*proposal-native8x.png')),
                REV/building/'eight-original-height-building-sections.png',
                REV/building/'source-attachment-context-3d.png']
    assert len(list((REV/contacts).glob('*.png'))) == 20
    assert len(list((REV/members).glob('*.png'))) == 7
    assert len(list((REV/building).glob('*proposal-native8x.png'))) == 10
    replay = json.loads((REV/'split-asite-building-standing17-hybrid-v6/first-hit-controls.json').read_bytes())
    assert len(replay['records']) == 4
    for row in replay['records']:
        hit = row['proposedHybridHit']
        assert hit['sourceObject'] == 5857
        assert abs(hit['displayedHitSvg'][1] - 56.809) < 1e-12
        endpoint = row['sideReceiver'][0]['paintedPathSegments'][0][-1]
        assert max(abs(a-b) for a,b in zip(hit['displayedHitSvg'], endpoint)) < 1e-12
    ledger = dict(
        scope='Root personally inspected listed source and actual SVG outline images. These are not composed application cones.',
        personallyViewed=[evidence(str(path.relative_to(REV)).replace('\\', '/')) for path in reviewed],
        gates=[evidence(f'{chain}/independent-chain-gate.json'),
               evidence('split-vent-room-finite-field-experiment-v6/independent-room-gate.json'),
               evidence('split-asite-building-raw-partition-v6/partition-review.json'),
               evidence('split-asite-building-standing17-hybrid-v6/first-hit-controls.json')],
        acceptedForOfflineStaging=[
            'Vent room V6 source members and wall contacts.',
            'Upper vent chain V2 at 169..172; preserve other finite source profiles.',
            'A-site building V6 source chain and doorway contacts, conditional on literal legacy17/7107 continuation.'],
        findings=[
            'All20 upper-chain native8x contacts meet the authored wall stroke on both sides.',
            'The10 A-site proposal native8x overlays align the reviewed walls and preserve doorway profiles.',
            'Four independent frozen A-site source standing rays now stop at SVG Y56.809, exactly at the painted-path endpoint.',
            'Original source sections retain higher headers, roofs, and real openings.'],
        limits=[
            'Upper doorway65/66 and high tower profiles are retained but not certified by the upper-chain contact gate.',
            'Literal defense169 differs by0.0008SVG and171 by0.0002SVG from attack coordinates.',
            'A-site7107 and old17 left continuation must survive cumulative ownership.',
            'Standing receiver policy, composed app cones, all-map coverage, and performance acceptance remain unfinished.'],
        productionPromotion=False)
    (REV/'root-v32-bounded-source-review.json').write_text(json.dumps(ledger, indent=2)+'\n')
    path = REV/'resume-wall-contact-priority-v29.json'
    state = json.loads(path.read_bytes())
    state['rootV32SourceReview'] = evidence('root-v32-bounded-source-review.json')
    state['activeAgentTasks'] = dict(
        vent_corner='ExplicitV31-based V32 staging; preserve legacy17/7107 continuation before bake.',
        asite_corner='Seal A-siteV6 independent gate and prove actual7107 interface.',
        paper_attachment='Sewer108 V5 attachment/partition/standing contacts; not yet accepted for staging.')
    path.write_text(json.dumps(state, indent=2)+'\n')
    print(REV/'root-v32-bounded-source-review.json')


if __name__ == '__main__':
    main()

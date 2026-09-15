"""Adjudicate source-ray differences under the authored SVG visibility model.

Raw source-ray diagnostics remain unchanged. This separate review records which
differences follow from authored XY placement or an explicit tactical decision.
Unrecognized source solids inside painted ink always remain unresolved.
"""
from collections import Counter
import json
import math
from pathlib import Path

import numpy as np
import shapely

from audit_all_map_gameplay_levels import MAPS, read
from compile_reviewed_svg_height_map import polygon
from resolve_local_svg_wall_profiles import OUTPUT, sha


# These object/outline pairs were inspected in the local eye-height galleries.
# They identify retained corners and frame ends, not a map-wide height waiver.
BOUNDARIES = {
    'abyss': {
        'p5-stroke-0': ([6028], 'A wall return projects past the source facade; keep the drawn return.'),
        'p7-stroke-15-p7-stroke-15-structural-remainder-0': ([6386], 'The crate return is offset from the measured crate side.'),
        'p1-stroke-6': ([6800, 6573, 6510, 6512, 6568], 'Retain the local pillar, catwalk wall, and railing ends around the separately reviewed open floor edge.'),
        'p11-stroke-2': ([4523], 'The small Tower wall projections meet the source facade beside its pipe recess.'),
    },
    'ascent': {
        'p1-fill-3': ([7559], 'Market north return ends beyond the source arch corner. The solid pier remains distinct from the arch opening.'),
    },
    'bind': {
        'p7-stroke-14': ([6531], 'Keep the drawn end of the balcony boundary where it joins the slanted facade.'),
        'p2-fill-0': ([4474, 626], 'Keep the authored Heaven entrance chamfer and the small rubble-wall return.'),
        'p2-fill-3': ([6868], 'The floor beam joins a closed authored corner; its local source end is inset.'),
        'p2-fill-4': ([2000, 6936], 'Reactor and pipe-kit source corners are inset from their painted wall corners.'),
        'p7-stroke-10': ([4337], 'The short joining stroke meets the solid niche; it is not a new gameplay aperture.'),
        'p2-fill-8': ([4473, 6535], 'Retain the Heaven entrance chamfer and Reactor tower return.'),
        'p2-fill-9': ([6972, 6975], 'The Baths doorway stays open between its solid, authored jambs.'),
    },
    'breeze': {
        'p0-stroke-4': ([5488], 'The Tunnel facade bends differently in the source and SVG. Its drawn corner remains a wall.'),
        'p0-stroke-12': ([6010], 'The vent assembly occupies the interior of the painted corner; retain the corner.'),
        'p0-stroke-14': ([5598], 'The small castle-arch pier is offset inside its painted obstacle outline.'),
        'p5-stroke-1': ([5738], 'Retain the boost-wall corner and the separate lower projection.'),
        'p6-stroke-0': ([5068], 'Retain the solid end piers of the separately reviewed upper overlook.'),
    },
    'corrode': {
        'p2-stroke-5': ([4926], 'Retain the Tower side-wall return beside the separately reviewed lower and upper openings.'),
    },
    'fracture': {
        'p3-stroke-0-p3-stroke-0-remainder-0': ([2084], 'Keep the short Shard box end where its painted outline exceeds the squared source corner.'),
        'p7-stroke-3-p7-stroke-3-remainder-0': ([5329, 4819, 4751], 'Retain solid upper-site and tunnel-frame ends around the separately reviewed lower passage.'),
        'p7-stroke-3-p7-stroke-3-remainder-1': ([4751], 'Retain the container frame end outside the confirmed lower tunnel aperture.'),
        'p13-stroke-4': ([4208], 'The A Door opening and solid jambs are separate. Keep the painted jamb ends; changing door states is outside this pass.'),
        'p18-stroke-0': ([4725, 4813, 4712], 'The site floor and tunnel ceiling remain solid at their measured heights; retain their authored ends.'),
    },
    'haven': {
        'p1-stroke-0': ([756], 'Retain the Hell opening frame beside the gameplay-confirmed open front.'),
        'p1-stroke-7': ([4425], 'The Rabsel header ends at the room corner. Retain its painted end; the source corner is inset.'),
    },
    'icebox': {
        'p1-fill-0': ([4551], 'The authored rear tunnel has a chamfer where the source entrance is straight.'),
        'p3-stroke-0': ([4454, 4455, 4457, 4459], 'Retain the raised connector edge and its junction with the separate ice wall.'),
        'p7-stroke-20': ([3747], 'Retain the stacked warehouse corner where the source base is slightly inset.'),
        'p14-stroke-8': ([4771], 'The small Tube hall projection is a closed structural obstacle, not a reviewed window.'),
        'p15-stroke-1': ([4306], 'The Snowman tunnel has a straight source wall and an authored diagonal return.'),
    },
    'lotus': {
        'p9-stroke-3': ([4722], 'Retain the short A back-wall joint; the source facade is inset.'),
        'p3-stroke-2': ([4604, 2597], 'Retain the C pillar corners around the solid pillar body.'),
        'p3-stroke-13': ([3143], 'Retain the authored A Main building jamb around the source doorway.'),
        'p6-stroke-0': ([4301, 4400, 4357], 'Retain the stepwell edge and represented statue/plinth obstacle where their local source silhouettes differ.'),
        'p8-stroke-3': ([3726, 3856, 3860, 3864], 'The C Mound ground edge is separate from the adjacent facade and overhead rock.'),
        'p8-stroke-7': ([3682], 'Retain the drawn column footprint around the narrower source column.'),
        'p8-stroke-10': ([3359], 'Retain the destroyed column assembly corners; local source outlines are inset and slanted.'),
        'p3-stroke-12': ([3027], 'Retain the A back-wall return at its source facade corner.'),
        'p10-stroke-0': ([4612, 4632], 'Retain the ruined-wall joining edge and C tower corner; source outlines differ at the joints.'),
    },
    'pearl': {
        'p5-stroke-0': ([6945], 'Retain the K2 building return around its inset source wall.'),
        'p7-stroke-9': ([7528], 'Retain the sewer return, whose authored cap precedes the source corner.'),
        'p14-stroke-0': ([6343], 'Retain the low Metro projection and the solid building junction.'),
        'p15-stroke-0': ([6364], 'Retain the generator body and base junction; source body ends and the authored base projection do not coincide.'),
        'p17-stroke-0': ([7806], 'Retain the small floor/building junction at the inset source wall end.'),
    },
    'summit': {
        'p1-stroke-7-structural-0': ([5884], 'Retain the painted entrance-door jamb around its inset source trim.'),
        'p2-stroke-2': ([6278], 'Retain the B Tower bottom-wall corners around the source body.'),
        'p2-stroke-3': ([6593], 'Retain the end piers of the separately reviewed Tower overlook.'),
        'p2-stroke-5': ([6354], 'Retain the Bottom Mid facade end; its source corner is inset.'),
    },
}

INSIDE_INK = {
    ('haven', 1069): ('unrepresented-decoration', 'The source hit is a small attacker-spawn flag attachment. The SVG contains the underlying boundary, not a separate flag obstacle.'),
    ('summit', 2554): ('unrepresented-decoration', 'The hit is a decorative VFX urn on the fence. The SVG represents the lower fence, not these separate ornaments.'),
    ('sunset', 1042): ('unrepresented-foliage', 'The hit is a cactus stem over the authored planter. The planter remains low cover; separate foliage is absent from the SVG.'),
    ('summit', 5120): ('source-placement-at-adjacent-crate-edge', 'The tall source crate overlaps the top edge of the neighboring low SVG crate. The source tall crate and its authored counterpart are offset in XY. Preserve both measured crate heights and their original painted footprints.'),
}


def review(name):
    directory = OUTPUT/name
    model = read(directory/'candidate-attack.json.gz')
    shapes = [polygon(w) for w in model['walls']]
    tree = shapely.STRtree(shapes)
    seed = read(directory/'seed-attack.json.gz')
    finite = {w['id']:w for w in seed['walls'] if not w['unknownHeight'] and all(hi is not None for _,hi in w['bands'])}
    raw = read(directory/'source-sightline-verification.json')
    ray_file = directory/'assumed-height-source-rays.json.gz'
    rays = read(ray_file)['findings']
    registration = read(directory/'source-registration-diagnostics.json')
    gaps = read(directory/'source-gap-playability.json')
    profiles = read(directory/'local-source-profiles.json')
    assert registration['sourceRaysSha256'] == sha(ray_file)
    assert gaps['sourceRaysSha256'] == sha(ray_file)
    assert registration['sourceProfilesSha256'] == sha(directory/'local-source-profiles.json')
    hashes = {s:sha(directory/f'candidate-{s}.json.gz') for s in ['attack','defense']}
    assert raw['candidateSha256'] == registration['candidateSha256'] == hashes
    assert raw['coveredInventoryRecords'] == raw['inventoryRecords']
    by_reg = {r['findingIndex']:r for r in registration['records']}
    by_gap = {r['findingIndex']:r for r in gaps['records']}
    records = []
    for i, row in enumerate(rays):
        r = by_reg[i]
        record = dict(findingIndex=i, wallId=row['wallId'], hitWallId=row['hitWallId'],
            differenceSvg=row['differenceSvg'], status='unresolved')
        if row['differenceSvg'] < 0:
            direction = np.array([math.cos(row['directionRadians']), math.sin(row['directionRadians'])])
            hit = np.array(row['originSvg'])+direction*row['sourceHit']
            point = shapely.Point(hit)
            inside = tree.query(point, predicate='intersects')
            record.update(sourceHitSvg=hit.tolist(), sourceObject=row.get('sourceObject'),
                          insidePaintedWalls=[model['walls'][j]['id'] for j in inside])
            if not len(inside):
                record.update(status='resolved', resolution='source-placement-outside-authored-ink',
                    reason='The first source solid lies outside every painted wall footprint. Adding a blocker there would change wall placement. The raw first-hit difference cannot constrain a wall height at that XY point.')
            elif (name,row.get('sourceObject')) in INSIDE_INK:
                resolution, reason = INSIDE_INK[name,row['sourceObject']]
                record.update(status='resolved', resolution=resolution, reason=reason)
        else:
            known = next((wid for wid in finite if row['hitWallId']==wid or
                          (row['hitWallId'] or '').startswith(wid+'-shared-')),None)
            if known:
                record.update(status='resolved', resolution='retained-reviewed-finite-wall',
                    originalFiniteWallId=known, reason='This earlier blocker is an existing finite wall, or its separately measured common facade edge. The new local profile does not introduce this source/SVG first-hit difference.')
            elif r['category']=='nearby-source-face-at-same-height':
                record.update(status='resolved', resolution='registered-local-facade',
                    nearbySourceContacts=r['nearbySourceContacts'],
                    reason='Shifted source rays hit the same local structural member at the same eye elevation beside the painted corner. Preserve the authored corner and the measured facade height.')
            else:
                rule = BOUNDARIES.get(name,{}).get(r.get('profileWallId'))
                if rule and r.get('sourceObject') in rule[0]:
                    record.update(status='resolved', resolution='reviewed-authored-boundary',
                        profileWallId=r['profileWallId'], sourceObject=r.get('sourceObject'), reason=rule[1])
                elif r['category']=='closed-across-local-source-height-gap' and not by_gap.get(i,{}).get('targetWitnesses'):
                    record.update(status='resolved', resolution='retained-unconfirmed-asset-gap',
                        profileWallId=r.get('profileWallId'), sourceObject=r.get('sourceObject'),
                        reason='Retain this painted tactical wall. A local asset gap alone does not establish a gameplay opening. The target search supplied no usable witness; this is not a claim that navigation absence proves the space inaccessible.')
        records.append(record)
    unresolved = [r for r in records if r['status']!='resolved']
    paths = ['source-sightline-verification.json','assumed-height-source-rays.json.gz',
             'source-registration-diagnostics.json','source-gap-playability.json',
             'local-source-profiles.json','compiled-height-profile-review.json','seed-attack.json.gz']
    if (directory/'shared-wall-edge-review.json').exists():paths.append('shared-wall-edge-review.json')
    report = dict(schemaVersion=1, map=name, status='passed' if not unresolved else 'blocked',
        rawFindings=len(rays), unresolvedFindings=len(unresolved),
        counts=dict(Counter(r.get('resolution','unresolved') for r in records)),
        candidateSha256=hashes, inputsSha256={p:sha(directory/p) for p in paths},
        reviewerAlgorithmSha256=sha(Path(__file__)), policySha256=sha(Path('docs/vision-model.md')),
        records=records,
        limitations=['Source XY and authored wall XY intentionally differ.',
            'Asset-only gaps remain tactical blockers unless separately confirmed as gameplay openings.',
            'These decisions resolve height-review leads; production rendering and standing verification are separate requirements.'])
    (directory/'source-height-semantic-review.json').write_text(json.dumps(report,separators=(',',':')))
    print(name,report['counts'],flush=True)
    if unresolved:
        print('UNRESOLVED',[(r['findingIndex'],by_reg[r['findingIndex']].get('profileWallId'),by_reg[r['findingIndex']].get('sourceObject'),r.get('sourceObject')) for r in unresolved],flush=True)
    return report


def require_semantic_review(directory):
    path = directory/'source-height-semantic-review.json'
    report = read(path)
    if report.get('status')!='passed' or report.get('unresolvedFindings')!=0:
        raise ValueError(f'Unresolved semantic height review: {directory.name}')
    if report.get('reviewerAlgorithmSha256')!=sha(Path(__file__)) or report.get('policySha256')!=sha(Path('docs/vision-model.md')):
        raise ValueError(f'Stale semantic review rules: {directory.name}')
    for p, digest in report['inputsSha256'].items():
        if sha(directory/p)!=digest:
            raise ValueError(f'Stale semantic review input {p}: {directory.name}')
    raw = read(directory/'source-sightline-verification.json')
    if raw['unresolvedFindings']!=report['rawFindings'] or len(report['records'])!=report['rawFindings']:
        raise ValueError(f'Incomplete semantic finding coverage: {directory.name}')
    if sorted(r['findingIndex'] for r in report['records'])!=list(range(report['rawFindings'])) or any(r['status']!='resolved' for r in report['records']):
        raise ValueError(f'Incomplete semantic decisions: {directory.name}')
    for side in ['attack','defense']:
        if report['candidateSha256'][side]!=sha(directory/f'candidate-{side}.json.gz'):
            raise ValueError(f'Stale semantic candidate: {directory.name}/{side}')


if __name__=='__main__':
    results = [review(name) for name in MAPS]
    if any(r['unresolvedFindings'] for r in results):raise SystemExit(1)

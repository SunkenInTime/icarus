"""Collect the complete assumed-wall review without turning measurements into approval.

Run after inspecting every page listed by each gallery manifest. The ledger
records that inspection separately from source association and gameplay approval.
"""
import argparse
import hashlib
import json
from pathlib import Path
import numpy as np
import shapely
from shapely.affinity import affine_transform

from audit_all_map_gameplay_levels import MAPS, ROOT, read
from compile_reviewed_svg_height_map import polygon
from inventory_assumed_svg_heights import DESTINATION


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


SPECIAL = {
    ('split', 'vent174-opening-0'):
        'Dara explicitly rejected this asset gap as a usable gameplay opening. '
        'Retain the tactical blocker. Its infinite top still needs a bounded '
        'structural height; the extracted gap must not override that gameplay decision.',
    ('icebox', 'p4-stroke-5'):
        'The saved right-end sightline is a confirmed false block. The paired Nest '
        'review partitions both ends from the same floor/base/interior/roof assembly. '
        'The remaining length of this compound path is still unresolved.',
    ('icebox', 'p5-stroke-10-nest-body-0'):
        'This compound path includes the opposite attacker Nest end. Its source '
        'assembly is solid at the upper eye height, unlike the other three ends. '
        'The paired review preserves that difference; remaining path height is unresolved.',
}


def summarize(output):
    maps, records, defense_records = [], [], []
    for name in MAPS:
        directory = output / name
        inventory = read(directory / 'assumed-height-review.json')
        sections = read(directory / 'assumed-height-sections.json')
        source_review = read(directory / 'source-sightline-verification.json')
        rays = read(directory / 'assumed-height-source-rays.json.gz')
        gallery = read(directory / 'assumed-height-gallery/manifest.json')
        by_section = {r['wallId']: r for r in sections['records']}
        by_coverage = {r['wallId']: r for r in rays['coverage']}
        by_gallery = {wid: p['file'] for p in gallery for wid in p['wallIds']}
        ids = {r['wallId'] for r in inventory['records']}
        if not ids == by_section.keys() == by_coverage.keys() == by_gallery.keys():
            raise ValueError((name, 'Incomplete inventory/sections/rays/gallery coverage'))
        if len(inventory['records']) != len(ids):
            raise ValueError((name, 'Duplicate wall identifiers'))
        for side in ['attack', 'defense']:
            if source_review['candidateSha256'][side] != digest(directory / f'candidate-{side}.json.gz'):
                raise ValueError((name, side, 'Candidate changed after source audit'))
        if source_review['rayRecordsSha256'] != digest(directory / 'assumed-height-source-rays.json.gz'):
            raise ValueError((name, 'Ray evidence changed'))
        specific_path = directory / 'specific-height-review.json'
        specific = {r['wallId']: r for r in read(specific_path)['records']} if specific_path.exists() else {}
        # The sides can partition the same ink differently. Inventory defense
        # records explicitly rather than assuming that record counts match.
        before_defense = read(directory / 'before-defense.json.gz')
        candidate_defense = read(directory / 'candidate-defense.json.gz')
        assumed = lambda w: w.get('unknownHeight', True) or any(hi is None for _, hi in w['bands'])
        defense_assumed = [w for w in before_defense['walls'] if assumed(w)]
        defense_review_path = directory / 'defense-height-review.json'
        defense_reviews = {r['wallId']: r for r in read(defense_review_path)['records']} if defense_review_path.exists() else {}
        defense_pending = shapely.union_all([shapely.make_valid(polygon(w))
            for w in candidate_defense['walls'] if assumed(w)])
        alignment = read(ROOT / f'tactical-alignment-sides-v1/{name}.json')
        attack_matrix, defense_matrix = [np.asarray(alignment[f'nativeTo{s}Svg']) for s in ['Attack', 'Defense']]
        linear = attack_matrix[:, :2] @ np.linalg.inv(defense_matrix[:, :2])
        shift = attack_matrix[:, 2] - linear @ defense_matrix[:, 2]
        transform = [*linear[0], *linear[1], *shift]
        shapes = [shapely.make_valid(polygon(r)) for r in inventory['records']]
        tree = shapely.STRtree(shapes)
        whole = shapely.union_all(shapes)
        for wall in defense_assumed:
            shape = shapely.make_valid(affine_transform(polygon(wall), transform))
            matches = [int(i) for i in tree.query(shape.buffer(.01), predicate='intersects')]
            overlap = [i for i in matches if shape.intersection(shapes[i].buffer(.01)).area > 1e-8]
            separate_review = defense_reviews.get(wall['id'])
            if not overlap and not separate_review:
                raise ValueError((name, wall['id'], 'Defense assumption missing from source review'))
            defense_records.append(dict(map=name, wallId=wall['id'], side='defense',
                status='unresolved-height' if shapely.make_valid(polygon(wall)).intersection(defense_pending).area > 1e-8
                    else 'candidate-correction',
                attackReviewWallIds=[inventory['records'][i]['wallId'] for i in overlap],
                separateSourceReview=separate_review,
                boundsInAttackSvg=list(shape.bounds),
                areaOutsideAttackAssumptionsSvg=shape.difference(whole).area,
                areaOutsideAuthoredRoundingToleranceSvg=shape.difference(whole.buffer(.01)).area,
                correspondenceToleranceSvg=.01,
                note='Source-profile review follows the corresponding physical region. '
                     'Defense artwork is preserved exactly; this tolerance is only for matching records.'))
        map_records = []
        for original in inventory['records']:
            wid = original['wallId']
            section, coverage = by_section[wid], by_coverage[wid]
            page = directory / 'assumed-height-gallery' / by_gallery[wid]
            objects = section['sourceObjects']
            findings = [rays['records'][i] for i in coverage['findingIndices']]
            repair = specific.get(wid)
            status = 'candidate-correction' if repair else 'unresolved-height'
            reasons = []
            if section['withoutSourceSection']:
                reasons.append(f"{section['withoutSourceSection']} local sections have no retained source geometry.")
            if not coverage['rays']:
                reasons.append('No valid automatic-standing probe was found; skipped reasons are recorded.')
            if findings:
                reasons.append(f'{len(findings)} source/SVG ray disagreements require location-specific review.')
            if not repair:
                reasons.append('Local geometry is measured, but its structural ownership and tactical meaning '
                               'have not been accepted as a complete finite wall profile.')
            note = SPECIAL.get((name, wid))
            if note:
                reasons.insert(0, note)
            if name == 'pearl' and any(o['object'] == 8218 for o in objects):
                reasons.append('The broad water-lid mesh 8218 overlaps this location. It cannot establish wall ownership.')
            row = dict(map=name, wallId=wid, parentWallId=original['parentWallId'],
                reviewConclusion='Reject the old unbounded height as reviewed source data.',
                status=status, oldBands=original['bands'],
                oldReviewStatus=original['previousEvidence'].get('reviewStatus')
                    if isinstance(original['previousEvidence'], dict) else None,
                oldUnknownHeight=original['unknownHeight'],
                boundsSvg=original['boundsSvg'],
                sourceSectionCount=len(section['stations']),
                unmatchedSourceSections=section['withoutSourceSection'],
                nearbySourceObjectCount=len(objects),
                leadingSourceObjects=objects[:5],
                sightlineProbes=coverage['rays'], skippedProbes=coverage['skipped'],
                sourceRayDisagreements=len(findings),
                representativeDisagreement=max(findings, key=lambda r: abs(r['differenceSvg'])) if findings else None,
                findings=reasons, candidateCorrection=repair,
                evidence=dict(gallery=str(page), gallerySha256=digest(page),
                    sections=str(directory / 'assumed-height-sections.json'),
                    rays=str(directory / 'assumed-height-source-rays.json.gz')))
            records.append(row)
            map_records.append(row)
        maps.append(dict(map=name, originalAssumptions=len(ids),
            originalDefenseAssumptions=len(defense_assumed),
            defenseOnlyCorrections=len(defense_reviews),
            remainingDefenseAssumptions=sum(assumed(w) for w in candidate_defense['walls']),
            candidateCorrections=len(specific), remainingAssumptions=source_review['assumedHeightRecords'],
            sourceSections=sum(r['sourceSectionCount'] for r in map_records),
            unmatchedSourceSections=sum(r['unmatchedSourceSections'] for r in map_records),
            wallsWithoutProbes=sum(r['sightlineProbes'] == 0 for r in map_records),
            physicalWallsWithoutProbes=source_review['physicalWallsWithoutProbes'],
            sourceRayDisagreements=source_review['unresolvedFindings'],
            rays=source_review['rays'], verifiedSourceTriangles=source_review['verifiedSourceTriangles'],
            sourceGeometrySha256=source_review['sourceGeometrySha256'],
            candidateSha256=source_review['candidateSha256'],
            galleryPages=len(gallery)))
    report = dict(schemaVersion=1, reviewDate='2026-09-08',
        status='audit-complete-height-resolution-incomplete',
        totals={key: sum(r[key] for r in maps) for key in maps[0]
                if isinstance(maps[0][key], int)},
        meanings=dict(candidateCorrection='Explicit bounded prop or annotation correction, still a draft asset.',
            unresolvedHeight='Inspected and measured; old assumption rejected. No complete replacement accepted.',
            sourceRayDisagreement='Audit finding, not a confirmed gameplay bug.',
            galleryReview='All listed source-profile pages were personally inspected during this review.'),
        maps=maps, records=records, defenseRecords=defense_records)
    (output / 'assumed-height-review-ledger.json').write_text(json.dumps(report, indent=2))
    print(json.dumps(report['totals']))
    return report


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, default=DESTINATION)
    args = parser.parse_args()
    summarize(args.output)

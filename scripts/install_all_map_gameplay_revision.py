"""Check the complete candidate set before replacing any bundled map asset."""
import argparse
import hashlib
import json
import math
from pathlib import Path
import shutil
import shapely
from audit_all_map_gameplay_levels import MAPS, OUT, read
from compile_reviewed_svg_height_map import polygon


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def require_resolved_heights(model):
    unresolved = [w['id'] for w in model['walls']
                  if w.get('unknownHeight', True)
                  or any(top is None or not math.isfinite(top)
                         for _, top in w['bands'])]
    if unresolved:
        raise ValueError(f'{len(unresolved)} assumed wall heights remain: {unresolved[:8]}')
    invalid = [w['id'] for w in model['walls'] if any(
        not math.isfinite(bottom) or top <= bottom for bottom, top in w['bands'])]
    if invalid:
        raise ValueError(f'Invalid runtime height intervals: {invalid[:8]}')


def require_sightline_review(directory):
    path = directory / 'source-sightline-verification.json'
    if not path.exists():
        raise ValueError(f'Missing independent source sightline review: {path}')
    report = read(path)
    if report.get('status') != 'passed' or report.get('unresolvedFindings') != 0:
        from review_svg_height_semantics import require_semantic_review
        require_semantic_review(directory)
    if not report.get('rays') or not report.get('verifiedSourceTriangles'):
        raise ValueError(f'Empty source sightline review: {path}')
    if (report.get('assumedHeightRecords') != 0
            or report.get('coveredInventoryRecords') != report.get('inventoryRecords')):
        raise ValueError(f'Incomplete source sightline review: {path}')
    from audit_assumed_svg_sightlines import reviewed_annotation_ids
    annotations = reviewed_annotation_ids(directory, read(directory / 'candidate-attack.json.gz'))
    if sorted(annotations) != report.get('annotationWallIds'):
        raise ValueError(f'Annotation classification changed after sightline review: {path}')
    classification = directory / 'specific-height-review.json'
    if report.get('classificationEvidenceSha256') != (digest(classification) if classification.exists() else None):
        raise ValueError(f'Classification evidence changed after sightline review: {path}')
    for side in ['attack', 'defense']:
        if report.get('candidateSha256', {}).get(side) != digest(directory / f'candidate-{side}.json.gz'):
            raise ValueError(f'Candidate changed after source sightline review: {directory.name}/{side}')
    from svg_review_source import source_world
    if report.get('sourceGeometrySha256') != digest(source_world(directory.name) / 'geometry.npz'):
        raise ValueError(f'Source changed after sightline review: {directory.name}')
    from audit_all_map_gameplay_levels import ROOT
    inputs = [('alignmentSha256', ROOT / f'tactical-alignment-sides-v1/{directory.name}.json'),
              ('sourcePackSha256', ROOT / f'tactical-visibility-revision/full-height-input-v1/{directory.name}/{directory.name}.height.bin.gz'),
              ('auditorSha256', Path(__file__).with_name('audit_assumed_svg_sightlines.py')),
              ('sourceNavigationSha256', ROOT / f'nav/baked/{directory.name}_source_xyz.json'),
              ('sourceWalkableNavigationSha256', ROOT / f'nav/baked/{directory.name}_navigation.json'),
              ('supplementarySourceAuditorSha256', Path(__file__).with_name('svg_represented_source_objects.py')),
              ('rayRecordsSha256', directory / 'assumed-height-source-rays.json.gz')]
    for key, source in inputs:
        if not source.exists() or report.get(key) != digest(source):
            raise ValueError(f'Stale source sightline review input {key}: {directory.name}')
    coverage = directory / 'source-coverage-poses.json'
    if report.get('supplementalCoveragePosesSha256') != (digest(coverage) if coverage.exists() else None):
        raise ValueError(f'Stale supplemental source coverage: {directory.name}')


def main():
    parser=argparse.ArgumentParser();parser.add_argument('--install',action='store_true')
    parser.add_argument('--directory',type=Path,default=OUT);args=parser.parse_args()
    records=[];copies=[]
    for name in MAPS:
        directory=args.directory/name
        for side in ['attack', 'defense']:
            require_resolved_heights(read(directory/f'candidate-{side}.json.gz'))
        require_sightline_review(directory)
        verification=read(directory/'support-verification.json')
        assert not verification['failures'],(name,'Standing verification failed')
        for side in ['attack','defense']:
            source=directory/f'candidate-{side}.json.gz';before=read(directory/f'before-{side}.json.gz');after=read(source)
            assert digest(source)==verification['candidateSha256'][side],(name,side,'Candidate changed after verification')
            for key in before:
                if key not in ['walls','supports','ground']:assert before[key]==after[key],(name,side,key)
            assert after['supports'][:len(before['supports'])]==before['supports'],(name,side,'Original supports changed')
            ink_before=shapely.union_all([polygon(w) for w in before['walls']]);ink_after=shapely.union_all([polygon(w) for w in after['walls']])
            error=ink_before.symmetric_difference(ink_after).area
            assert error<1e-7,(name,side,'Painted wall footprint changed',error)
            # GEOS can retain a zero-area seam where split polygons rejoin.
            # Remove sub-nanopixel arithmetic seams for the boundary metric;
            # the unsnapped painted-area difference is checked above.
            assert shapely.set_precision(ink_before,1e-8).hausdorff_distance(shapely.set_precision(ink_after,1e-8))<1e-7
            automatic=sum(bool(s.get('automaticStandingAllowed')) for s in after['supports'])
            assert automatic>0,(name,side,'No automatic standing coverage')
            records.append(dict(map=name,side=side,sha256=digest(source),compressedBytes=source.stat().st_size,
                previousCompressedBytes=(directory/f'before-{side}.json.gz').stat().st_size,
                supports=len(after['supports']),automaticSupports=automatic,walls=len(after['walls']),
                infiniteWallAssumptions=sum(any(top is None for _,top in w['bands']) for w in after['walls']),
                groundTriangles=len(after['ground']['triangles'])//3,paintedWallDifferenceAreaSvg=error,
                verifiedStandingPositions=verification['sampledPositions']))
            copies.append((source,Path(f'assets/maps/{name}_svg_height_{side}.json.gz')))
    if args.install:
        for source,destination in copies:shutil.copyfile(source,destination)
        for source,destination in copies:assert digest(source)==digest(destination)
    (args.directory/'asset-integrity.json').write_text(json.dumps(dict(installed=args.install,records=records),indent=2))
    print(json.dumps(dict(installed=args.install,maps=len(MAPS),assets=len(records),
        compressedBytes=sum(r['compressedBytes'] for r in records),
        automaticSupports=sum(r['automaticSupports'] for r in records if r['side']=='attack'),
        verifiedStandingPositions=sum(r['verifiedStandingPositions'] for r in records if r['side']=='attack'))))


if __name__=='__main__':main()

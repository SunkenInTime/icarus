"""Bind the completed production exports to the installed finite-height candidates."""
import json
from pathlib import Path
import numpy as np
from audit_all_map_gameplay_levels import MAPS, ROOT, read
from resolve_local_svg_wall_profiles import OUTPUT, sha


def main():
    review = ROOT / 'tactical-visibility-revision'
    original = review / 'finite-production-v7b'
    fracture = review / 'finite-production-v7c-fracture'
    boundaries = [original / 'boundary-audit.json', fracture / 'boundary-audit.json']
    assert all(read(p)['flaggedCones'] == 0 for p in boundaries)
    records = []
    for name in MAPS:
        directory = OUTPUT / name
        renders = fracture if name == 'fracture' else original / name
        manifest = renders / 'manifest.json'
        rows = read(manifest)['records']
        fixtures = read(directory / 'production-cases.json')
        assert len(rows) == len(fixtures['cases'])
        assert {r['id'] for r in rows} == {r['id'] for r in fixtures['cases']}
        hashes = {s: sha(directory / f'candidate-{s}.json.gz') for s in ['attack', 'defense']}
        assert hashes == fixtures['candidateSha256']
        for side in hashes:
            assert read(OUTPUT / f'render-models/{name}-{side}.json') == read(directory / f'candidate-{side}.json.gz')
        assert all(len(r['polygonSvg']) >= 3 for r in rows)
        assert all(r['receiverContainsOrigin'] for r in rows if 'image' in r)
        assert all(r['nativeReferenceBoundaryDifferenceSvg'] < 1e-6 for r in rows)
        assert all(abs(r['eyeElevationMeters'] - r['expectedEyeElevationMeters']) < 1e-4 for r in rows)
        timings = [r['queryWithStandingMicroseconds'] for r in rows]
        source = read(directory / 'source-sightline-verification.json')
        semantics = read(directory / 'source-height-semantic-review.json')
        assert semantics['unresolvedFindings'] == source['assumedHeightRecords'] == 0
        records.append(dict(map=name, candidateSha256=hashes, manifest=str(manifest),
            manifestSha256=sha(manifest), fixtureSha256=sha(directory/'production-cases.json'),
            queries=len(rows), renders=sum('image' in r for r in rows),
            nativeQueryIncludingStandingMedianMicros=float(np.median(timings)),
            nativeQueryIncludingStandingP95Micros=float(np.percentile(timings,95)),
            nativeQueryIncludingStandingMaxMicros=max(timings),
            sourceRays=source['rays'], reviewedOriginalWallRecords=source['inventoryRecords'],
            rawSourceDifferences=source['unresolvedFindings'], semanticDecisions=semantics['counts']))
    selection = original / 'inspection/selection.json'
    report = dict(status='passed', records=records,
        queries=sum(r['queries'] for r in records), renders=sum(r['renders'] for r in records),
        boundaryAudits={str(p):sha(p) for p in boundaries},
        visualInspection=dict(selection=str(selection), selectionSha256=sha(selection),
            sheetsInspected=list(range(1,17)),
            replacementImagesInspected=[str(fracture/f'{s}-opening-3.png') for s in ['attack','defense']]),
        limitations=['Test-process timings are not desktop frame times.',
            'The original boundary audit includes superseded Fracture fixtures. The separate Fracture audit verifies all replacement fixtures.',
            'Source/SVG differences remain in the raw audit, with separate explicit height-semantic decisions.'])
    (OUTPUT / 'production-verification.json').write_text(json.dumps(report,indent=2))
    print(json.dumps({k:v for k,v in report.items() if k in ['status','queries','renders']}))


if __name__ == '__main__':
    main()

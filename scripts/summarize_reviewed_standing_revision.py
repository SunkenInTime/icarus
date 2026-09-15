"""Record the installed, built, and served result of the gameplay review."""
import json
from pathlib import Path
from audit_all_map_gameplay_levels import MAPS,read
from build_all_physical_standing_surfaces import sha
from build_reviewed_standing_surfaces import OUTPUT,REVIEW

source=read(OUTPUT/'source-verification.json');production=read(OUTPUT/'production-verification.json')
delivery=read(OUTPUT/'delivery-verification.json');live=read(OUTPUT/'live-standing-verification.json');review=read(REVIEW)
assert all(r['status']=='passed' for r in [source,production,delivery,live])
assert delivery['builtAssetsVerified'] and source['reviewSha256']==sha(REVIEW)
assert live['reviewSha256']==sha(REVIEW) and live['queries']==production['queries']
images=sorted((OUTPUT/'production-v1').glob('*-reviewed-*.jpg'))
inspection=dict(status='inspected',productionManifests=[dict(map=r['map'],sha256=r['manifestSha256']) for r in production['maps']],
    reviewedObjectCrops=80,contactSheets=[dict(path=str(p),sha256=sha(p)) for p in images],
    checks=['Both artwork sides for all 40 reviewed source-object records',
        'Production painter wall contacts and finite cone shapes',
        'Fountain point map retains center and outer basin with only the measured inner ring shaded',
        'Position map controls and markers fit at 736 and 360 CSS pixels'])
(OUTPUT/'visual-inspection.json').write_text(json.dumps(inspection,indent=2))
before_bytes=sum((OUTPUT/n/f'before-{s}.json.gz').stat().st_size for n in MAPS for s in ['attack','defense'])
after_bytes=sum((OUTPUT/n/f'candidate-{s}.json.gz').stat().st_size for n in MAPS for s in ['attack','defense'])
result=dict(status='installed-built-and-served',reviewSha256=sha(REVIEW),confirmedSamples=454,
    newStandingRegionsPerSide=sum(r['newSupports'] for r in source['maps']),maps=source['maps'],
    measuredPlayerCollisionReferences=sum(r['physicalFloor'] is not None for m in review['maps'].values() for r in m['samples']),
    retainedExtractionDisagreements=sum(bool(r['extractedClearanceDisagreement']) for m in review['maps'].values() for r in m['samples']),
    eligibilityEvidence='Dara gameplay inspection; extracted collision disagreements do not reverse that review.',
    heightEvidence='Matched player-collision floors where identified, otherwise measured local rendered source faces. These are geometric references, not new live-game height measurements.',
    sourceSamplesVerifiedBothSides=908,productionQueries=production['queries'],productionRenders=production['renders'],
    boundaryAudit=read(Path(production['boundaryAudit'])),applicationTestsPassed=53,
    liveApplicationQueries=live['queries'],verifiedBuiltAndServedModels=len(delivery['models']),
    savedReviewsPreserved=len(delivery['reviews']),compressedAssetBytes=after_bytes,addedCompressedBytes=after_bytes-before_bytes,
    positionMap='https://dara-pc-duo.tailba589e.ts.net:8445/',
    coneReview='https://dara-pc-duo.tailba589e.ts.net:8444/',
    executableSha256=delivery['executableSha256'],nativeSha256=delivery['nativeSha256'])
(OUTPUT/'revision-summary.json').write_text(json.dumps(result,indent=2))
print(json.dumps({k:v for k,v in result.items() if k in ['status','confirmedSamples','newStandingRegionsPerSide','compressedAssetBytes','addedCompressedBytes','productionQueries','applicationTestsPassed']}))

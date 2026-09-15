"""Retain original triangles for every wall union that failed section checks."""
import argparse
import gzip
import json
from pathlib import Path
import numpy as np
from lift_reviewed_wall_source_heights import sha


def retain(source, section_review, output):
    if output.exists():
        raise FileExistsError(output)
    report = json.loads((source/'report.json').read_text())
    review = json.loads(section_review.read_text())
    data = json.loads(gzip.decompress((source/'wall-profiles.json.gz').read_bytes()))
    assert sha(source/'wall-profiles.json.gz') == report['profileSha256'] == review['profileSha256']
    assert data['oraclePackSha256'] == review['oraclePackSha256']
    assert sha(source/'assignment.npz') == report['assignmentSha256']
    assert [row['region'] for row in review['regions']] == list(range(len(data['regions'])))
    failed = {row['region'] for row in review['failures']}
    for row in review['regions']:
        if row['maximumSectionSymmetricDifferenceSvg'] >= 1e-8 or row['maximumEndpointDistanceSvg'] >= 1e-8:
            assert row['region'] in failed
    kept = [index for index in range(len(data['regions'])) if index not in failed]
    with np.load(source/'assignment.npz') as archive:
        before = archive['profileRegion']
        before_residual = archive['residualOracleFaces']
    assert np.array_equal(before_residual,np.flatnonzero(before < 0))
    after = np.full_like(before,-1)
    for new, old in enumerate(kept):
        after[before == old] = new
    residual = np.flatnonzero(after < 0)
    assert np.array_equal(np.sort(np.r_[np.flatnonzero(after >= 0),residual]),np.arange(len(before)))
    assert (after[before < 0] < 0).all()
    checked = [data['regions'][index] for index in kept]
    data['regions'] = checked
    data['sectionReviewSha256'] = sha(section_review)
    data['originalRegionIds'] = kept
    data['rejectedRegionIds'] = sorted(failed)
    output.mkdir(parents=True)
    raw = json.dumps(data,separators=(',',':'),allow_nan=False).encode()
    profile_path = output/'wall-profiles.json.gz'
    profile_path.write_bytes(gzip.compress(raw,mtime=0))
    np.savez_compressed(output/'assignment.npz',profileRegion=after,residualOracleFaces=residual)
    result = dict(scope=__doc__,oraclePackSha256=data['oraclePackSha256'],oracleTriangles=len(before),
        profileTriangles=int((after>=0).sum()),residualTriangles=len(residual),regions=len(checked),
        rejectedRegions=len(failed),trianglesReturnedToOriginalForm=int(((before>=0)&(after<0)).sum()),
        compressedProfileBytes=profile_path.stat().st_size,rawProfileBytes=len(raw),
        assignmentBytes=(output/'assignment.npz').stat().st_size,
        profileSha256=sha(profile_path),assignmentSha256=sha(output/'assignment.npz'),
        sourceProfileSha256=report['profileSha256'],sectionReviewSha256=sha(section_review),
        selectedRegionSourceIds=kept,originalTriangleRetentionVerified=True,compilerSha256=sha(Path(__file__)),
        productionMutation=False,limitations=['Passing sampled sections are a bounded check, not an exact-arithmetic union proof.',
            'All rejected, masked and unmatched faces stay in the referenced original oracle.',
            'No inverse-W runtime, whole-map byte or performance claim.'])
    (output/'report.json').write_text(json.dumps(result,indent=2)+'\n')
    print(json.dumps(result,indent=2))


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    for key in ['source','section_review','output']:
        parser.add_argument(key,type=Path)
    retain(**vars(parser.parse_args()))

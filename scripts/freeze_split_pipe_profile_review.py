"""Freeze approved pipe proposal inputs and compact, explicitly scoped controls."""
import gzip
import json
from pathlib import Path

import numpy as np

from native_compact_wall_profiles import sha
from native_reference_cast import NativeReferenceModel
from tactical_alignment_composite import explicit_warp
from verify_split_pipe_profile_proposal import REV


def main():
    folder=REV/'split-pipe130-profile-region-proposal-v5'
    output=folder/'regression-fixtures.json'
    assert not output.exists()
    declaration=json.loads((folder/'region-declaration.json').read_text())
    source_review=REV/'split-clove-pipe7479-review-v3/review.json'
    review=json.loads(source_review.read_text());query=np.asarray(review['actualQuery'])
    warp_path=REV/'display-warps-v1/split.display-warp.json.gz'
    warp=json.loads(gzip.decompress(warp_path.read_bytes()))
    native=np.asarray(warp['sourceNativeMeters']).reshape(-1,2);target=np.asarray(warp['targetAttackSvg']).reshape(-1,2)
    inverse=explicit_warp(target,native-target,np.asarray(warp['triangles']).reshape(-1,3))
    candidate=REV/'split-wall-family-normalized-candidate-v26'
    caster=NativeReferenceModel(candidate/'split.height.bin.gz',REV/'native-tactical-rays-build/Release/tactical_reference_cast.dll')
    full=NativeReferenceModel(REV/'full-height-input-v1/split/split.height.bin.gz',REV/'native-tactical-rays-build/Release/tactical_reference_cast.dll')
    absolute_eye=review['originalObserverEyeMeters'];fixtures=[]
    a,b=np.asarray(declaration['pipe130ProfileProposal']['target130'])
    def ray(target_svg,eye,extension=1.):
        goal=inverse.apply(np.asarray(target_svg)[None])[0];delta=goal-query[:2];length=np.linalg.norm(delta)
        end=query[:2]+delta*(1+extension/length);direction=delta/length
        return [*query[:2],eye,*direction,length+extension,.04],[*end,eye]
    for index,fraction in enumerate([.35,.55,.75]):
        target_svg=a+fraction*(b-a)
        relative,end=ray(target_svg,query[2]);absolute,absolute_end=ray(target_svg,absolute_eye)
        fixtures.append(dict(id=f'clove-pipe130-standing-{index}',targetSvg=target_svg.tolist(),
            provisionalAppQuery=relative,originalStandingSourceQuery=absolute,
            originalStandingFeetMeters=absolute_eye-1.75,
            expectedAuthoredStopSegment=[a.tolist(),b.tolist()],expectedSourceAssembly=[7478,7479,7480,7481,7633,7634,7609],
            scope='Same frozen observer XY. Check provisional app and original-Z oracle separately; the two vertical policies are not equivalent.'))
    upper=json.loads((folder/'upper-elbow-backing-receiver-review.json').read_text())
    for row in upper['records']:
        if row['originalSourceHeightMeters'] not in [11.5,12.0]:continue
        target_svg=[241.8,216.92]
        original,end=ray(target_svg,row['originalSourceHeightMeters'])
        fixtures.append(dict(id=f"clove-pipe-upper-tail-{row['originalSourceHeightMeters']:g}",
            sourceQuery=original,targetNative=end,targetSvg=target_svg,eyeMode='original-world-Z',
            expectedFirstBlockingAssembly=[7609],expectedStopSpans=[130,131,102],
            receiverControl=dict(tailGeoJson=row['tailGeoJson'],expectedAttackAndDefenseFillIntersectionLengthSvg=0.),
            sourceJoinPoints=row['mappedSourceContactPoints'],
            scope='Synthetic elevated height at frozen XY. It is not a claim that this is a reachable standing pose. The elbow tail must remain behind the connected wall and outside the receiver.'))
    for index,target_svg in enumerate([[224.,212.5],[228.,212.5],[231.,212.5]]):
        relative,end=ray(target_svg,query[2],.2);absolute,absolute_end=ray(target_svg,absolute_eye,.2)
        fixtures.append(dict(id=f'clove-left-opening-invariant-{index}',targetSvg=target_svg,
            provisionalAppQuery=relative,originalSourceQuery=absolute,
            frozenV26AppFirstHit=caster.cast(relative[:3],end),
            frozenOriginalSourceFirstHit=full.cast(absolute[:3],absolute_end),
            expected='Preserve each respective control result and left doorway/header mapping. Do not compare the two different vertical policies as equivalent.',
            unchangedSourceXMaximum=declaration['pipe130ProfileProposal']['sourceBox'][0]))
    report=dict(schemaVersion=1,map='split',status='Approved proposal controls; no candidate bake or runtime acceptance',
        declarationSha256=sha(folder/'region-declaration.json'),sourceReviewSha256=sha(source_review),
        frozenControlPackSha256=sha(candidate/'split.height.bin.gz'),sourceGeometrySha256=review['sourceGeometrySha256'],
        fullOriginalSourcePackSha256=review['fullSourcePackSha256'],displayWarpSha256=sha(warp_path),fixtures=fixtures)
    output.write_text(json.dumps(report,indent=2)+'\n')
    paths=[folder/name for name in ['region-declaration.json','proposal-review.json','independent-contact-height-review.json',
        'upper-elbow-backing-receiver-review.json','profile-preview.png','exact-height-sections.png',
        'upper-elbow-backing-receiver-context.png','regression-fixtures.json']]
    paths.extend([source_review,source_review.parent/'source-context.npz',source_review.parent/'recommendation.json'])
    index=dict(status='Root personally reviewed and approved the connected pipe/port proposal for next cumulative candidate after Barrier V28 source checks.',
        familyEdge=200190,sourceObjectsAdded=[7478,7479,7480,7481,7633,7634],separateObjectExcluded=3963,
        geometryBakePerformed=False,productionMutation=False,
        review=[dict(path=str(p),sha256=sha(p)) for p in paths],
        builderScriptSha256=sha(Path(__file__).with_name('propose_split_pipe_profile_region.py')),
        fixtureBuilderSha256=sha(Path(__file__)),
        nextGates=['Cumulative source fragment partition, originalZ/UV/material preservation and shared attachment checks.',
                   'Same frozen ten-agent app replay, standing130 controls, elevated tail backing and left-opening invariance.'])
    (folder/'frozen-review-index.json').write_text(json.dumps(index,indent=2)+'\n')
    print(json.dumps(dict(fixtures=len(fixtures),declarationSha256=report['declarationSha256'],output=str(output)),indent=2))


if __name__=='__main__':main()

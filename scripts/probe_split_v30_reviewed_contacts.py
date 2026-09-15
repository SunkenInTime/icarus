"""Bounded reviewed-contact measurements and frozen plank height controls."""
import gzip
import json
from pathlib import Path
import numpy as np
from native_reference_cast import NativeReferenceModel
from tactical_alignment_composite import explicit_warp
from native_compact_wall_profiles import sha

ROOT=Path('E:/IcarusWorldAudit/2026-09-06');REV=ROOT/'tactical-visibility-revision'


def distance(point,segments):
    segments=np.asarray(segments);a=segments[:,0];delta=segments[:,1]-a
    t=np.clip(np.sum((point-a)*delta,axis=1)/np.sum(delta*delta,axis=1),0,1)
    return float(np.linalg.norm(point-a-t[:,None]*delta,axis=1).min())


def main():
    folder=REV/'split-pipe-generator-render-candidate-v30';output=folder/'reviewed-contact-and-plank-controls.json';assert not output.exists()
    prior=json.loads((folder/'native-first-hit-review.json').read_text())
    wpath=REV/'display-warps-v1/split.display-warp.json.gz';w=json.loads(gzip.decompress(wpath.read_bytes()))
    native=np.array(w['sourceNativeMeters']).reshape(-1,2);target=np.array(w['targetAttackSvg']).reshape(-1,2)
    warp=explicit_warp(native,target-native,np.array(w['triangles']).reshape(-1,3))
    coverage=json.loads(gzip.decompress((REV/'all-map-wall-span-coverage-v1/split/attack.coverage.json.gz').read_bytes()))
    spans={r['span']:[r['startSvg'],r['endSvg']] for r in coverage['spans']}
    gen=json.loads((REV/'split-generator-connected-profile-proposal-v4/region-declaration.json').read_text())['generatorReview']['cubic204']
    cubic=[[r['startSvg'],r['endSvg']] for r in gen['segments']]
    expected={
        'generator-north-top-cover':[[[56.3212,161.54],[63.764,161.54]]],
        'generator-north-above-top-cover':[spans[202]],
        'generator-south-lower-cover':[[[69.6119,194.501],[77.5864,194.501]]],
        'generator-south-upper-cover':[[[69.6119,194.501],[77.5864,194.501]]],
        'generator-south-above-both-covers':cubic,
        'generator-generator-left':[spans[203]],
        'generator-generator-right':[spans[205]],
        'generator-generator-curved-front':cubic,
    }
    for i in range(3):expected[f'clove-pipe130-standing-{i}']=[spans[130]]
    rows=[]
    for record in prior['rows']:
        if record['id'] not in expected:continue
        hits={}
        for label,hit in record['firstHits'].items():
            assert hit is not None
            xy=warp.apply(np.asarray(hit['point'])[None,:2])[0]
            hits[label]=dict(pointSvg=xy.tolist(),distanceFromReviewedTargetPolylineSvg=distance(xy,expected[record['id']]),sourceObject=hit['sourceObject'])
        rows.append(dict(id=record['id'],hits=hits))
    plank_config=REV/'gallery-plank-v29-source-controls-v1/candidate-config.json'
    queries=json.loads(plank_config.read_text())['maps']['split']['queriesById']
    cfull=np.load(REV/'global-ground-complete-v2/split/correspondence.npz')['sourceFaces'];raw=np.load(REV/'full-height-input-v1/split/source-correspondence.npz')['sourceFaces'][cfull]
    meta=json.loads((ROOT/'supplemented-v2/world/split/geometry.json').read_text());starts=np.array([o['firstFace'] for o in meta['objects']])
    planks={identifier:dict(query=q,firstHits={}) for identifier,q in queries.items()}
    for label,path in [('control',REV/'split-wall-family-normalized-candidate-v29'),('candidate',REV/'split-wall-family-normalized-candidate-v30-cached-v1')]:
        caster=NativeReferenceModel(path/'split.height.bin.gz',REV/'native-tactical-rays-build/Release/tactical_reference_cast.dll')
        parents=np.load(path/'correspondence.npz')['sourceFaces']
        for identifier,query in queries.items():
            query=np.array(query);end=query[:3].copy();end[:2]+=query[3:5]*query[5]
            hit=caster.cast(query[:3],end)
            if hit:
                source=int(raw[parents[hit['face']]]);owner=int(np.searchsorted(starts,source,side='right')-1)
                xy=warp.apply(np.asarray(hit['point'])[None,:2])[0]
                hit.update(originalSourceFace=source,sourceObject=owner,sourceObjectPath=meta['objects'][owner]['path'],pointSvg=xy.tolist(),distanceToReviewedBarrierSpansSvg=distance(xy,[spans[i] for i in range(121,126)]))
            planks[identifier]['firstHits'][label]=hit
    above=planks['plank-122-notch-above-top'];standing=planks['plank-122-notch-standing']
    assert above['query'][2]==2.75 and standing['query'][2]==1.75
    assert standing['firstHits']['control']['sourceObject'] in [501,502]
    assert above['firstHits']['candidate']['sourceObject'] not in [501,502]
    literal_above_same_source_face=above['firstHits']['control']['originalSourceFace']==above['firstHits']['candidate']['originalSourceFace']
    above_distance_change=above['firstHits']['candidate']['distanceMeters']-above['firstHits']['control']['distanceMeters']
    report=dict(packSha256=prior['packSha256'],contactRows=rows,plankControls=planks,
        cubicPolylineControlHullErrorBoundSvg=gen['maxControlHullDistanceBoundSvg'],
        scope='Attack-authored target geometry and unchanged physical queries; defense artwork rounding and native raster coverage require separate review.',
        plankFixtureConfigSha256=sha(plank_config),aboveControlLiteralSameSourceFace=literal_above_same_source_face,
        aboveControlDistanceChangeMeters=above_distance_change,productionMutation=False)
    output.write_text(json.dumps(report,indent=2)+'\n')
    print(json.dumps(dict(contacts=rows,planks=planks),indent=2))
    assert abs(above_distance_change)<1e-8, 'Above-plank sightline changed; inspect saved report'


if __name__=='__main__':main()

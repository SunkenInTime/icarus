"""Exact source lineage for frozen Boat V5 standing and elevated render poses."""
import argparse
import bisect
import gzip
import json
from pathlib import Path
import numpy as np
from native_reference_cast import NativeReferenceModel
from native_compact_wall_profiles import sha
from tactical_alignment_composite import explicit_warp
from prepare_ascent_connected_corners import ROOT,REV


def main(folder=None):
    folder=Path(folder) if folder else REV/'ascent-connected-boat-candidate-v5';fixture_path=folder/'render-fixtures/ascent-fixtures.json';config_path=folder/'render-fixtures/candidate-config.json'
    fixtures=json.loads(fixture_path.read_text())['cases'];cfg=json.loads(config_path.read_text())['maps']['ascent']
    warp_path=Path(cfg['displayWarpFile']);w=json.loads(gzip.decompress(warp_path.read_bytes()));source=np.array(w['sourceNativeMeters']).reshape(-1,2);target=np.array(w['targetAttackSvg']).reshape(-1,2);cells=np.array(w['triangles']).reshape(-1,3);forward=explicit_warp(source,target-source,cells);inverse=explicit_warp(target,source-target,cells)
    caster=NativeReferenceModel(folder/'ascent.height.bin.gz',REV/'native-tactical-rays-build/Release/tactical_reference_cast.dll')
    chains=[np.load(p)['sourceFaces'] for p in [folder/'correspondence.npz',REV/'global-ground-complete-v2/ascent/correspondence.npz',REV/'full-height-input-v1/ascent/source-correspondence.npz']]
    metadata_path=ROOT/'supplemented-v2/world/ascent/geometry.json';objects=json.loads(metadata_path.read_text())['objects'];starts=[o['firstFace'] for o in objects]
    selected_ids={'span-205-end-corner','span-206-center','span-206-start-corner','span-207-start-corner'}
    rows=[]
    for fixture in fixtures:
        if fixture['id'] not in selected_ids and not fixture['id'].endswith(('higher-source-profile','above-entire-boat-profile')):continue
        query=np.asarray(cfg['queriesById'][fixture['id']]);origin=query[:3];direction=query[3:5];direction/=np.linalg.norm(direction)
        a,b=np.asarray(fixture['boundedTargetLineSvg']);tangent=(b-a)/np.linalg.norm(b-a);normal=np.array([-tangent[1],tangent[0]])
        if (np.asarray(fixture['originSvg'])-a)@normal<0:normal=-normal
        samples=[]
        for t in np.arange(.005,np.linalg.norm(b-a),.01):
            point=a+t*tangent;goal=inverse.apply(point[None])[0];delta=goal-origin[:2];length=np.linalg.norm(delta)
            if delta@direction/length<np.cos(query[6]/2) or length>query[5]:continue
            end=origin[:2]+delta*(1+1/length);hit=caster.cast(origin,np.r_[end,origin[2]])
            sample=dict(alongSvg=float(t),pointSvg=point.tolist())
            if hit:
                displayed=forward.apply(np.array(hit['point'][:2])[None])[0];ids=[hit['face']]
                for chain in chains:ids.append(int(chain[ids[-1]]))
                oid=bisect.bisect_right(starts,ids[-1])-1
                sample.update(faceChain=ids,sourceObject=oid,sourcePath=objects[oid]['path'],hitSvg=displayed.tolist(),hitNative=hit['point'],normalOffsetSvg=float((displayed-point)@normal),masked=hit['masked'])
            else:sample['clear']=True
            samples.append(sample)
        counts={str(oid):sum(s.get('sourceObject')==oid for s in samples) for oid in sorted({s['sourceObject'] for s in samples if 'sourceObject' in s})}
        early={str(oid):sum(s.get('sourceObject')==oid and s.get('normalOffsetSvg',0)>1e-5 for s in samples) for oid in sorted({s['sourceObject'] for s in samples if s.get('normalOffsetSvg',0)>1e-5})}
        rows.append(dict(id=fixture['id'],query=query.tolist(),samples=samples,sourceHitCounts=counts,earlySourceHitCounts=early,aboveEntireBoatProfile=bool(origin[2]>4.0974222995705105)))
        print(fixture['id'],len(samples),'hits',counts,'early',early)
        if origin[2]>4.0974222995705105:assert not any(s.get('sourceObject')==7206 for s in samples),'Elevated ray hit boat despite original-height maximum'
    report=dict(scope=__doc__,candidatePackSha256=sha(folder/'ascent.height.bin.gz'),fixtureSha256=sha(fixture_path),configSha256=sha(config_path),warpSha256=sha(warp_path),metadataSha256=sha(metadata_path),scriptSha256=sha(Path(__file__)),records=rows,limitations='Frozen original-XY/control-relative-Z poses. Source first hits establish exact identity within that policy; no live-game floor or rendering acceptance claim.')
    (folder/'frozen-render-contact-sources.json').write_text(json.dumps(report,indent=2)+'\n')


if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('candidate',nargs='?');main(p.parse_args().candidate)

"""Replay the renderer's frozen wall-contact rays with original source lineage."""
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


def main(folder):
    folder=Path(folder)
    trace_path=REV/'ascent-component5-control-v5-evidence/frozen-contact-first-hits.json'
    trace=json.loads(trace_path.read_text())
    warp_path=REV/'display-warps-v1/ascent.display-warp.json.gz'
    warp=json.loads(gzip.decompress(warp_path.read_bytes()))
    source=np.asarray(warp['sourceNativeMeters']).reshape(-1,2)
    target=np.asarray(warp['targetAttackSvg']).reshape(-1,2)
    cells=np.asarray(warp['triangles']).reshape(-1,3)
    forward=explicit_warp(source,target-source,cells)
    inverse=explicit_warp(target,source-target,cells)
    caster=NativeReferenceModel(folder/'ascent.height.bin.gz',REV/'native-tactical-rays-build/Release/tactical_reference_cast.dll')
    chains=[np.load(path)['sourceFaces'] for path in [folder/'correspondence.npz',REV/'global-ground-complete-v2/ascent/correspondence.npz',REV/'full-height-input-v1/ascent/source-correspondence.npz']]
    metadata_path=ROOT/'supplemented-v2/world/ascent/geometry.json'
    objects=json.loads(metadata_path.read_text())['objects'];starts=[o['firstFace'] for o in objects]
    rows=[]
    for row in trace['records']:
        a,b=np.asarray(row['authoredEnds']);tangent=(b-a)/np.linalg.norm(b-a);normal=np.array([-tangent[1],tangent[0]])
        origin=np.asarray(row['query'][:3]);observer=forward.apply(origin[None,:2])[0]
        if (observer-a)@normal<0:normal=-normal
        samples=[]
        for previous in row['samples']:
            point=np.asarray(previous['pointSvg']);goal=inverse.apply(point[None])[0];delta=goal-origin[:2];end=origin[:2]+delta*(1+1/np.linalg.norm(delta))
            hit=caster.cast(origin,np.r_[end,origin[2]])
            result=dict(alongSvg=previous['alongSvg'],pointSvg=point.tolist(),priorSourceObject=previous.get('sourceObject'),priorNormalOffsetSvg=previous.get('hitNormalOffsetSvg'))
            if hit:
                displayed=forward.apply(np.asarray(hit['point'][:2])[None])[0];ids=[hit['face']]
                for chain in chains:ids.append(int(chain[ids[-1]]))
                oid=bisect.bisect_right(starts,ids[-1])-1
                result.update(hitSvg=displayed.tolist(),hitNative=hit['point'],hitNormalOffsetSvg=float((displayed-point)@normal),sourceObject=oid,sourcePath=objects[oid]['path'],faceChain=ids,masked=hit['masked'])
            else:result['clearPastLine']=True
            samples.append(result)
        early=[s for s in samples if s.get('hitNormalOffsetSvg',0)>.05]
        rows.append(dict(id=row['id'],query=row['query'],samples=samples,
                         earlySourceObjects=sorted({s['sourceObject'] for s in early}),
                         maximumNormalOffsetSvg=max((s.get('hitNormalOffsetSvg',0) for s in samples),default=0)))
        print(row['id'],len(samples),'early',rows[-1]['earlySourceObjects'],'max',rows[-1]['maximumNormalOffsetSvg'])
    report=dict(scope=__doc__,candidatePackSha256=sha(folder/'ascent.height.bin.gz'),
                frozenTraceSha256=sha(trace_path),warpSha256=sha(warp_path),sourceMetadataSha256=sha(metadata_path),
                scriptSha256=sha(Path(__file__)),records=rows,
                limitation='Same provisional control-relative queries and original alpha sampler. This is a source first-hit diagnostic, not a renderer coverage or live-game floor test.')
    (folder/'frozen-mounted-contact-replay.json').write_text(json.dumps(report,indent=2)+'\n')


if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('candidate');main(p.parse_args().candidate)

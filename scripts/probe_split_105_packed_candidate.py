"""Replay all frozen105 receiver endpoints against both complete packed candidates."""
import argparse
import gzip
import json
from pathlib import Path
import numpy as np
from native_reference_cast import NativeReferenceModel
from native_compact_wall_profiles import sha
from tactical_alignment_composite import explicit_warp

REV=Path('E:/IcarusWorldAudit/2026-09-06/tactical-visibility-revision')


def main(candidate,output):
    output.mkdir(exist_ok=False)
    fixture=REV/'split-105-v31-render-fixtures-v2/all-source-rays.json';records=json.loads(fixture.read_text())['records']
    wp=REV/'display-warps-v1/split.display-warp.json.gz';w=json.loads(gzip.decompress(wp.read_bytes()))
    native=np.array(w['sourceNativeMeters']).reshape(-1,2);target=np.array(w['targetAttackSvg']).reshape(-1,2);forward=explicit_warp(native,target-native,np.array(w['triangles']).reshape(-1,3))
    rawmeta=REV.parent/'supplemented-v2/world/split/geometry.json';objects=json.loads(rawmeta.read_text())['objects'];starts=np.array([o['firstFace'] for o in objects])
    control=np.load(REV/'global-ground-complete-v2/split/correspondence.npz')['sourceFaces'];full=np.load(REV/'full-height-input-v1/split/source-correspondence.npz')['sourceFaces'];controlraw=full[control]
    folders=[REV/'split-wall-family-normalized-candidate-v30-cached-v1',candidate]
    casters=[NativeReferenceModel(folder/'split.height.bin.gz',REV/'native-tactical-rays-build/Release/tactical_reference_cast.dll') for folder in folders]
    sources=[controlraw[np.load(folder/'correspondence.npz')['sourceFaces']] for folder in folders]
    results=[]
    for record in records:
        q=np.array(record['query']);end=np.r_[q[:2]+q[3:5]*q[5],q[2]];hits=[]
        # Literal reviewed start/end XY and original eye are in sourceEvidence.
        # Current runtime uses its provisional relative-ground Z, as labeled.
        np.testing.assert_allclose(end[:2],record['sourceEvidence']['queryEnd'][:2],atol=1e-13,rtol=0)
        for caster,raw in zip(casters,sources):
            hit=caster.cast(q[:3],end,end_padding=0.,end_inclusive=True)
            if hit:
                source=int(raw[hit['face']]);owner=int(np.searchsorted(starts,source,side='right')-1)
                hit.update(rawSourceFace=source,sourceObject=owner,sourcePath=objects[owner]['path'],hitSvg=forward.apply(np.array(hit['point'])[None,:2])[0].tolist())
            hits.append(hit)
        results.append(dict(id=record['id'],query=q.tolist(),selectedForRender=record['selectedForRender'],
            sourceHybridExpected=record['sourceEvidence']['proposedHybridHit'],before=hits[0],after=hits[1]))
    summary=dict(samples=len(results),beforeBlocked=sum(r['before'] is not None for r in results),afterBlocked=sum(r['after'] is not None for r in results),
        opened=sum(r['before'] is not None and r['after'] is None for r in results),closed=sum(r['before'] is None and r['after'] is not None for r in results),
        afterObjects=sorted({r['after']['sourceObject'] for r in results if r['after']}))
    report=dict(summary=summary,records=results,fixtureSha256=sha(fixture),displayWarpSha256=sha(wp),sourceMetadataSha256=sha(rawmeta),
        beforePackSha256=sha(folders[0]/'split.height.bin.gz'),afterPackSha256=sha(candidate/'split.height.bin.gz'),scriptSha256=sha(Path(__file__)),
        scope='All195 literal source endpoint rays through completeV30/V31 packed models. Zuses existing provisional ground-relative runtime policy. Compare sourceHybridExpected as context, not a proof of equivalence to horizontal original-world rays. No production mutation.')
    (output/'report.json').write_text(json.dumps(report,indent=2)+'\n');print(json.dumps(summary,indent=2))


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('candidate',type=Path);parser.add_argument('output',type=Path)
    a=parser.parse_args();main(a.candidate,a.output)

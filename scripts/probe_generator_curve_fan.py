"""Source rays versus the actual frozen native shadow mesh at cubic204."""
import gzip
import argparse
import json
from pathlib import Path
import numpy as np
from audit_wall_contact_pixels import PhysicalGeometry
from native_reference_cast import NativeReferenceModel
from tactical_alignment_composite import explicit_warp
from native_compact_wall_profiles import sha

ROOT=Path('E:/IcarusWorldAudit/2026-09-06');REV=ROOT/'tactical-visibility-revision'


def main(out=None,manifest_path=None,path=None):
    out=out or REV/'generator-v30-curved-front-source-fan-v2';out.mkdir(exist_ok=False)
    manifest_path=manifest_path or REV/'pipe-generator-contact-v30-candidate-v1/manifest.json';manifest=json.loads(manifest_path.read_text())
    case=next(r for r in manifest['cases'] if r['id']=='generator-generator-curved-front' and r['side']=='attack')
    defense=next(r for r in manifest['cases'] if r['id']==case['id'] and r['side']=='defense')
    mesh_path=Path(case['prefix']+'-shadow.f32');mesh=np.fromfile(mesh_path,dtype='<f4')
    assert sha(mesh_path)==case['meshSha256']
    w=json.loads(gzip.decompress(Path(manifest['displayWarpFile']).read_bytes()))
    geometry=PhysicalGeometry(w,case,mesh);q=np.array(case['query'])
    native=np.array(w['sourceNativeMeters']).reshape(-1,2);target=np.array(w['targetAttackSvg']).reshape(-1,2)
    forward=explicit_warp(native,target-native,np.array(w['triangles']).reshape(-1,3))
    controls=np.array(json.loads((REV/'split-generator-connected-profile-proposal-v4/region-declaration.json').read_text())['generatorReview']['cubic204']['controls'])
    t=np.linspace(0,1,2001);points=(1-t[:,None])**3*controls[0]+3*(1-t[:,None])**2*t[:,None]*controls[1]+3*(1-t[:,None])*t[:,None]**2*controls[2]+t[:,None]**3*controls[3]
    derivative=3*((1-t[:,None])**2*(controls[1]-controls[0])+2*(1-t[:,None])*t[:,None]*(controls[2]-controls[1])+t[:,None]**2*(controls[3]-controls[2]))
    normal=np.column_stack((-derivative[:,1],derivative[:,0]));normal/=np.linalg.norm(normal,axis=1)[:,None]
    observer=forward.apply(q[None,:2])[0]
    normal[np.sum((observer-points)*normal,axis=1)<0]*=-1
    valid=geometry.in_frustum(points,margin=True)
    points=points[valid];normal=normal[valid];t=t[valid]
    offsets=np.arange(-.15,.15001,.00025)
    clear=geometry.clear((points[:,None]+normal[:,None]*offsets[None,:,None]).reshape(-1,2)).reshape(len(points),-1)
    path=path or REV/'split-wall-family-normalized-candidate-v30-cached-v1'
    caster=NativeReferenceModel(path/'split.height.bin.gz',REV/'native-tactical-rays-build/Release/tactical_reference_cast.dll')
    parent=np.load(path/'correspondence.npz')['sourceFaces'];control=np.load(REV/'global-ground-complete-v2/split/correspondence.npz')['sourceFaces'];raw=np.load(REV/'full-height-input-v1/split/source-correspondence.npz')['sourceFaces'][control[parent]]
    objects=json.loads((ROOT/'supplemented-v2/world/split/geometry.json').read_text())['objects'];starts=np.array([r['firstFace'] for r in objects])
    rows=[]
    for i,(point,n,parameter) in enumerate(zip(points,normal,t)):
        goal=geometry.native(point)[0];delta=goal-q[:2];direction=delta/np.linalg.norm(delta)
        hit=caster.cast(q[:3],np.r_[goal+direction*.2,q[2]])
        lit=offsets[clear[i]]
        row=dict(t=float(parameter),authoredCurveSvg=point.tolist(),towardObserverNormal=n.tolist(),
            meshFirstClearNormalOffsetSvg=float(lit.min()) if len(lit) else None,
            meshClearBehindCurve005=bool(clear[i,np.argmin(abs(offsets+.005))]),
            meshClearBeforeCurve005=bool(clear[i,np.argmin(abs(offsets-.005))]))
        if hit:
            xy=forward.apply(np.array(hit['point'])[None,:2])[0];source=int(raw[hit['face']]);owner=int(np.searchsorted(starts,source,side='right')-1)
            row.update(sourceHit=hit,sourceObject=owner,originalSourceFace=source,hitSvg=xy.tolist(),
                hitNormalOffsetSvg=float((xy-point)@n),hitTangentResidualSvg=float(abs(n[0]*(xy-point)[1]-n[1]*(xy-point)[0])))
        rows.append(row)
    summary=dict(samples=len(rows),query=q.tolist(),observerSvg=observer.tolist(),
        maximumSourceHitOffsetSvg=max(abs(r['hitNormalOffsetSvg']) for r in rows if 'sourceHit' in r),
        sourceObjects=sorted({r['sourceObject'] for r in rows if 'sourceHit' in r}),
        missingSourceHits=sum('sourceHit' not in r for r in rows),
        meshFirstClearRangeSvg=[min(r['meshFirstClearNormalOffsetSvg'] for r in rows if r['meshFirstClearNormalOffsetSvg'] is not None),max(r['meshFirstClearNormalOffsetSvg'] for r in rows if r['meshFirstClearNormalOffsetSvg'] is not None)],
        meshClearBehind005=sum(r['meshClearBehindCurve005'] for r in rows),
        meshBlockedBefore005=sum(not r['meshClearBeforeCurve005'] for r in rows),
        attackDefenseQueryIdentical=case['query']==defense['query'],attackDefenseNativeMeshIdentical=case['meshSha256']==defense['meshSha256'])
    report=dict(summary=summary,rows=rows,manifestSha256=sha(manifest_path),nativeMeshSha256=sha(mesh_path),
        candidatePackSha256=sha(path/'split.height.bin.gz'),offsetSamplingStepSvg=.00025,
        scope='Actual frozen native shadow triangles versus independent source casts across authored attack cubic. No raster or ink classification.',productionMutation=False)
    (out/'report.json').write_text(json.dumps(report,indent=2)+'\n');print(json.dumps(summary,indent=2))


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--output',type=Path);parser.add_argument('--manifest',type=Path);parser.add_argument('--candidate',type=Path)
    args=parser.parse_args();main(args.output,args.manifest,args.candidate)

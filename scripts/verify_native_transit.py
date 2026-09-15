"""Moving-origin native shortcut comparisons, with original source oracle."""
import argparse
import json
from pathlib import Path
import numpy as np
from probe_source_floor_regressions import load_support,source_model
from verify_native_floor_atlas import NativeAtlas


def run(revision,rays):
    source=source_model(revision,'split',True);support=load_support(revision,'split',True)
    control=NativeAtlas(revision,source,transit=False);candidate=NativeAtlas(revision,source,transit=True)
    certificate=json.loads((revision/'sheet-transit-certificate-v1/split.json').read_text())
    parent_planes={parent['parent']:np.array(parent['sourcePlane']) for parent in certificate['parents']}
    center=np.array([20.599371111492427,39.59257844288108])
    poses=[('annotated-clove',center,None),('parent320',[23.35,37.25],parent_planes[320]),
           ('parent322',[23.725,39.25],parent_planes[322]),('parent324',[24.1625,41],parent_planes[324]),
           ('parent326',[22.3875,41],parent_planes[326]),('parent328',[22.604761904761904,42.6],parent_planes[328])]
    rng=np.random.default_rng(841423);reports=[];failures=[]
    for label,xy,plane in poses:
        samples=[]
        for i in range(rays):
            position=np.array(xy)+rng.uniform(-.05,.05,2)
            z=6.781631480113873 if plane is None else float(np.r_[position,1]@plane+1.75)
            origin=np.r_[position,z];angle=rng.uniform(0,2*np.pi);direction=np.array([np.cos(angle),np.sin(angle)])
            distance=min(5.,6-max(abs(position-center))-.01)
            expected=support.cast(source,origin,direction,distance,True,True,True,.35,True)
            before=control.cast(source,origin,direction,distance);after=candidate.cast(source,origin,direction,distance)
            error=max(abs(before['distanceMeters']-expected['distanceMeters']),abs(after['distanceMeters']-expected['distanceMeters']))
            samples.append(dict(errorMeters=float(error),controlNativeSeconds=before['nativeSeconds'],candidateNativeSeconds=after['nativeSeconds'],
                                beforePieces=len(before['rows']),afterPieces=len(after['rows']),transitPieces=after['transitPieces'],fallbacks=after['fallbacks']))
            if error>1e-5:
                failures.append(dict(pose=label,origin=origin.tolist(),direction=direction.tolist(),distance=distance,errorMeters=float(error),
                                     expected=expected,before={**before,'rows':before['rows'].tolist()},after={**after,'rows':after['rows'].tolist()}))
        report=dict(id=label,rays=len(samples),maximumErrorMeters=max(sample['errorMeters'] for sample in samples),
                    transitPieces=sum(sample['transitPieces'] for sample in samples),
                    meanControlPieces=float(np.mean([sample['beforePieces'] for sample in samples])),
                    meanCandidatePieces=float(np.mean([sample['afterPieces'] for sample in samples])),
                    controlNativeP95Milliseconds=float(np.quantile([sample['controlNativeSeconds'] for sample in samples],.95)*1000),
                    candidateNativeP95Milliseconds=float(np.quantile([sample['candidateNativeSeconds'] for sample in samples],.95)*1000))
        reports.append(report);print(json.dumps(report),flush=True)
    result=dict(scope=__doc__,poses=reports,failures=failures,limitation='Bounded local atlas, default standing source selection with unknown roles retained. Per-ray cost is not a completed high-refresh cone runtime.')
    (revision/'local-floor-atlas-v1/split-transit-verification.json').write_text(json.dumps(result,indent=2)+'\n')
    print(len(failures),'failures',flush=True)


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('revision',type=Path);parser.add_argument('--rays',type=int,default=128)
    args=parser.parse_args();run(args.revision,args.rays)

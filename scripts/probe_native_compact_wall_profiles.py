"""Native compact profiles vs full candidate BVH on the frozen profile probe grid."""
import argparse,gzip,json,time
from pathlib import Path
import numpy as np
import shapely
from native_compact_wall_profiles import NativeProfiles,compile_input,sha
from native_reference_cast import NativeReferenceModel

def run(folder,candidate,warp_path,library,output):
    output.mkdir(exist_ok=False,parents=True);path=folder/'wall-profiles.json.gz';data=json.loads(gzip.decompress(path.read_bytes()));warp=json.loads(gzip.decompress(warp_path.read_bytes()));pack=candidate/f'{data["map"]}.height.bin.gz'
    assert sha(pack)==data['candidatePackSha256'];assert sha(warp_path)==data['displayWarpSha256']
    arrays,refs,(back,matrix,origin)=compile_input(data,warp);np.savez_compressed(output/'native-input.npz',points=arrays[0],rings=arrays[1],pieces=arrays[2],pieceFamilies=arrays[3],maskedProfiles=arrays[4],maskFamilies=arrays[5]);(output/'masked-references.json').write_text(json.dumps(refs,indent=2))
    model=NativeProfiles(library,*arrays);source=NativeReferenceModel(pack,library);provenance=np.load(candidate/'normalized-face-provenance.npz');edge_by_face=dict(zip(provenance['generatedFaceIds'].tolist(),provenance['generatedEdges'].tolist()))
    queries=[];metadata=[]
    for fi,f in enumerate(data['families']):
        region=shapely.from_geojson(json.dumps(f['opaqueRegion']));lo,zlo,hi,zhi=region.bounds;grid=np.array(np.meshgrid(np.linspace(lo,hi,61),np.linspace(zlo-.01,zhi+.01,31))).reshape(2,-1).T;vertices=shapely.get_coordinates(region);offsets=np.array([[1e-5,0],[-1e-5,0],[0,1e-5],[0,-1e-5]]);probes=np.unique(np.vstack((grid,(vertices[:,None]+offsets).reshape(-1,2))),axis=0);points=shapely.points(probes);numerical=shapely.distance(points,region.boundary)<=1e-8;masked=np.zeros(len(probes),bool)
        for item in f['maskedProfiles']:masked|=shapely.covers(shapely.Polygon(item['profile']).buffer(1e-8),points)
        expected=shapely.covers(region,points);frame=f['targetFrame'];o,t,n=(np.array(frame[k]) for k in ['origin','tangent','normal']);svg=o+probes[:,:1]*t;contacts=(back.apply(svg)-origin)@np.linalg.inv(matrix).T
        for sign in [-1,1]:
            starts=(back.apply(svg+n*sign*.001)-origin)@np.linalg.inv(matrix).T
            for i in range(len(probes)):
                queries.append([*starts[i],probes[i,1],*(2*contacts[i]-starts[i]),probes[i,1]]);metadata.append([fi,probes[i,0],probes[i,1],expected[i],numerical[i],masked[i],sign])
    queries=np.array(queries);meta=np.array(metadata);native,mask_hits=model.cast(queries);bvh=model.bvh(source,queries);np.savez_compressed(output/'queries-results.npz',queries=queries,metadata=meta,native=native,maskedDistances=mask_hits,bvh=bvh)
    counts=dict(matched=0,sourceExteriorHalo=0,otherSourceFamily=0,maskedRegionExcluded=0,numericalRegionExcluded=0,nativeBoundaryFlag=0);failures=[];max_error=0.;halos=[]
    for i,(q,row,a,b) in enumerate(zip(queries,meta,native,bvh)):
        fi=int(row[0]);edge=data['families'][fi]['edge'];face=int(b[0]);source_edge=edge_by_face.get(face,-1)
        if row[4]:counts['numericalRegionExcluded']+=1;continue
        if row[5] or (face>=0 and source.arrays['faceMasks'][face]>=0) or np.isfinite(mask_hits[i]).any():counts['maskedRegionExcluded']+=1;continue
        if face>=0 and source_edge!=edge:counts['otherSourceFamily']+=1;continue
        if a[2] or a[3]:counts['nativeBoundaryFlag']+=1
        ahit=np.isfinite(a[0]);bhit=face>=0;expected=bool(row[3]);valid=ahit==expected and ahit==bhit
        if bhit and not expected:
            bary=np.array([1-b[2]-b[3],b[2],b[3]])
            if -1.01e-7<=bary.min()<-1e-10 and not ahit:counts['sourceExteriorHalo']+=1;halos.append(dict(query=i,face=face,minBary=float(bary.min())));continue
        if ahit and bhit:max_error=max(max_error,abs(a[0]-b[1]));valid=valid and abs(a[0]-b[1])<1e-8
        if valid:counts['matched']+=1
        else:failures.append(dict(query=i,edge=edge,profileBlocked=expected,native=a.tolist(),bvh=b.tolist(),point=row[1:3].tolist()))
    # Same full query array, balanced order; source batch is unmasked first-hit BVH traversal only.
    timings={'profiles':[],'bvh':[]}
    for order in [('profiles','bvh'),('bvh','profiles')]*4:
        for kind in order:
            begin=time.perf_counter_ns();model.cast(queries) if kind=='profiles' else model.bvh(source,queries);timings[kind].append((time.perf_counter_ns()-begin)/1e6)
    report=dict(scope=__doc__,profileSha256=sha(path),candidatePackSha256=sha(pack),librarySha256=sha(library),queries=len(queries),families=len(data['families']),nativeInputBytes=(output/'native-input.npz').stat().st_size,originalProfileGzipBytes=path.stat().st_size,nativePieces=len(arrays[2]),ringVertices=len(arrays[0]),maskedReferences=len(refs),counts=counts,mismatches=failures,mismatchCount=len(failures),maximumMatchedDistanceErrorMeters=max_error,exteriorHalos=halos,timingMs=timings,medianNanosecondsPerQuery={k:float(np.median(v))*1e6/len(queries) for k,v in timings.items()},limitations=['Only reviewed planar wall families, not an entire map or cone.','All seven masked profiles preserve references and return hit candidates; alpha sampling is not implemented by this consumer.','Numerical boundaries and source barycentric exterior halos remain explicit; no profile dilation.','BVH timing is native first geometric hit; it excludes texture sampling.','Timing includes native batch/FFI output allocation, excludes decoding and model creation.'],productionMutation=False)
    (output/'report.json').write_text(json.dumps(report,indent=2)+'\n');print(json.dumps({k:report[k] for k in ['queries','nativeInputBytes','nativePieces','counts','mismatchCount','maximumMatchedDistanceErrorMeters','medianNanosecondsPerQuery']},indent=2));model.close()
    assert not failures, f'Native compact wall profiles have {len(failures)} eligible mismatches; report preserved at {output}'
if __name__=='__main__':
    p=argparse.ArgumentParser();[p.add_argument(k,type=Path) for k in ['folder','candidate','warp','library','output']];a=p.parse_args();run(a.folder,a.candidate,a.warp,a.library,a.output)

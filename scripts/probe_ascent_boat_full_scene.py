"""Bounded standing-pose boat replacement control with full source occlusion."""
import ctypes,gzip,json
from pathlib import Path
import numpy as np
import shapely
from shapely import Point,LineString,Polygon,union_all
from native_reference_cast import NativeReferenceModel
from world_visibility_ray_reference import sample_alpha
from native_compact_wall_profiles import sha
from prepare_ascent_connected_corners import ROOT,REV,OUT
from tactical_alignment_composite import explicit_warp
from authored_wall_profile_cells import frame_wall_breakpoints
from audit_null_material_receiver_scope import source_receiver


def main():
    pack=REV/'full-height-input-v1/ascent/ascent.height.bin.gz';library=REV/'native-rounded-profile-oracle-build/build/Release/rounded_profile_oracle.dll'
    source=NativeReferenceModel(pack,library)
    packet_path=OUT/'boat-208-profile-source.npz';packet=np.load(packet_path)
    boat=set(map(int,packet['fullSourceFaces']));profile=union_all([Polygon(x) for x in packet['projectedAlongZ'] if Polygon(x).area>0])
    original=np.load(pack.parent/'source-correspondence.npz')['sourceFaces']
    meta=json.loads((ROOT/'supplemented-v2/world/ascent/geometry.json').read_text());starts=np.array([o['firstFace'] for o in meta['objects']])
    affine=np.array(json.loads((ROOT/'tactical-alignment-sides-v1/ascent.json').read_text())['nativeToAttackSvg']);inv=np.linalg.inv(affine[:,:2])
    line=packet['authoredEndpoints'];t=line[1]-line[0];length=np.linalg.norm(t);t/=length;n=np.array([-t[1],t[0]])
    wpath=REV/'display-warps-v1/ascent.display-warp.json.gz';w=json.loads(gzip.decompress(wpath.read_bytes()));wp=np.array(w['sourceNativeMeters']).reshape(-1,2)@affine[:,:2].T+affine[:,2];wt=np.array(w['targetAttackSvg']).reshape(-1,2)
    inverse_w=explicit_warp(wt,wp-wt,np.array(w['triangles']).reshape(-1,3))
    frame=dict(origin=line[0],tangent=t,normal=n);breaks=np.array([0,*frame_wall_breakpoints(inverse_w,frame,0,length),length]);wall_native=(inverse_w.apply(line[0]+breaks[:,None]*t)-affine[:,2])@inv.T
    receiver=source_receiver(REV,'ascent')

    def scene_without_finite_boat(a,b):
        # Exclude the hit of a boat face only when it belongs to the finite source
        # along strip. Outside boat fragments stay unchanged, including triangles
        # crossing the strip boundary. All other source/alpha tests remain exact.
        a,b=np.asarray(a,dtype=float),np.asarray(b,dtype=float);direction=b-a;direction/=np.linalg.norm(direction);excluded=[];out=np.zeros(3);fp=ctypes.POINTER(ctypes.c_double);ip=ctypes.POINTER(ctypes.c_int32)
        while True:
            ids=np.array(excluded or [-1],dtype=np.int32)
            face=source.nearest(*source.pointers,a.ctypes.data_as(fp),b.ctypes.data_as(fp),0.,0.,1,ids.ctypes.data_as(ip),len(excluded),out.ctypes.data_as(fp))
            if face==-2:raise RuntimeError('BVH stack overflow')
            if face<0:return None
            distance,u,v=out;hit=a+direction*distance;s=((hit[:2]@affine[:,:2].T+affine[:,2])-line[0])@t
            skip=face in boat and 0<=s<=length
            mask=int(source.arrays['faceMasks'][face])
            if not skip and mask>=0:
                material=source.materials[int(source.arrays['maskedMaterials'][mask])];uv=np.array([1-u-v,u,v])@source.arrays['maskedUvs'][mask]
                skip=sample_alpha(source.textures[material['texture']],uv,material)<material['threshold']
            if skip:excluded.append(face);continue
            return dict(face=int(face),distanceMeters=float(distance),point=hit.tolist())

    navpath=REV/'baseline-world/ascent_navigation.json.gz';nav=json.loads(gzip.decompress(navpath.read_bytes()));detail=nav['floorMesh'];ui=json.loads((REV/'baseline-world/height_catalog.json').read_text())['maps']['ascent']['uiTransform'];v=np.array(detail['vertices'],dtype=float).reshape(-1,3);uv=v[:,:2]/detail['coordinateScale'];v[:,0]=(uv[:,1]-ui['YScalarToAdd'])/(100*ui['YMultiplier']);v[:,1]=-(uv[:,0]-ui['XScalarToAdd'])/(100*ui['XMultiplier']);v[:,2]/=100;f=np.array(detail['triangles']).reshape(-1,4)
    midpoint=wall_native.mean(0);origins=[];seen=set();rejected=dict(outsideReceiver=0,noMatchingSourceFloor=0)
    for floor_id,row in enumerate(f):
        if not nav['walkable'][row[0]]:continue
        tri=v[row[1:]]
        if np.linalg.norm(tri[:,:2].mean(0)-midpoint)>11:continue
        for bary in [[1/3]*3,[.6,.2,.2],[.2,.6,.2],[.2,.2,.6]]:
            p=np.array(bary)@tri;key=tuple(np.rint(p/.25).astype(int))
            if key in seen:continue
            seen.add(key)
            if not receiver.covers(Point(p[:2])):rejected['outsideReceiver']+=1;continue
            floorhit=source.cast(p+[0,0,.04],p-[0,0,.04],min_distance=0,end_padding=0,end_inclusive=True)
            if floorhit is None or abs(floorhit['point'][2]-p[2])>.03 or abs(floorhit['normal'][2])<.5:rejected['noMatchingSourceFloor']+=1;continue
            feet=np.array(floorhit['point']);eye=feet+[0,0,1.75]
            origins.append(dict(eye=eye.tolist(),feet=feet.tolist(),navParent=int(row[0]),navDetailTriangle=floor_id,navZ=float(p[2]),sourceFloorFace=int(original[floorhit['face']])))
    print('standing origins',len(origins),flush=True)
    queries=[];changed=[];counts=dict(queries=0,finiteProfileIntersections=0,sourceDistanceDifferencesAbove1mm=0,receiverDifferencesAbove1mm=0,profileHiddenByOtherSource=0)
    for oi,pose in enumerate(origins):
        a=np.array(pose['eye'])
        for s in np.linspace(.002,length-.002,25):
            target=(inverse_w.apply((line[0]+s*t)[None])[0]-affine[:,2])@inv.T;d=target-a[:2];to_line=np.linalg.norm(d)
            if to_line<.1:continue
            d/=to_line;range_m=min(22.,to_line+8);b=a+np.r_[d,0]*range_m
            crossings=[]
            for j,(p,q) in enumerate(zip(wall_native[:-1],wall_native[1:])):
                edge=q-p;matrix=np.column_stack((d,-edge));det=np.linalg.det(matrix)
                if abs(det)<1e-14:continue
                distance,u=np.linalg.solve(matrix,p-a[:2])
                if not(0<=u<=1 and 0<=distance<=range_m):continue
                along=breaks[j]+u*(breaks[j+1]-breaks[j])
                if profile.covers(Point(along,a[2])):crossings.append(float(distance))
            old=source.cast(a,b,min_distance=0,end_padding=0,end_inclusive=True);other=scene_without_finite_boat(a,b)
            old_d=range_m if old is None else old['distanceMeters'];other_d=range_m if other is None else other['distanceMeters'];profile_d=min(crossings,default=range_m);new_d=min(other_d,profile_d)
            counts['queries']+=1;counts['finiteProfileIntersections']+=bool(crossings);counts['profileHiddenByOtherSource']+=bool(crossings and other_d<profile_d)
            delta=abs(old_d-new_d)
            if delta<=.001:continue
            counts['sourceDistanceDifferencesAbove1mm']+=1
            segment=LineString([a[:2]+d*min(old_d,new_d),a[:2]+d*max(old_d,new_d)]);visible=segment.intersection(receiver).length
            counts['receiverDifferencesAbove1mm']+=visible>.001
            def fact(hit):
                if hit is None:return None
                raw=int(original[hit['face']]);obj=int(np.searchsorted(starts,raw,side='right')-1)
                return dict(fullSourceFace=hit['face'],originalSourceFace=raw,sourceObject=obj,sourcePath=meta['objects'][obj]['path'],point=hit['point'],distanceMeters=hit['distanceMeters'])
            changed.append(dict(originIndex=oi,targetAlongSvg=float(s),query=[a.tolist(),b.tolist()],oldDistance=old_d,candidateDistance=new_d,profileDistance=profile_d,receiverDifferenceMeters=float(visible),originalHit=fact(old),otherHit=fact(other)))
        if oi%100==0:print('origin',oi,'queries',counts['queries'],'eligible differences',counts['receiverDifferencesAbove1mm'],flush=True)
    report=dict(format='icarus-boat-full-scene-standing-control-v1',sourcePackSha256=sha(pack),sourceCorrespondenceSha256=sha(pack.parent/'source-correspondence.npz'),sourcePacketSha256=sha(packet_path),displayWarpSha256=sha(wpath),navigationSha256=sha(navpath),scriptSha256=sha(Path(__file__)),counts=counts,rejectedOrigins=rejected,origins=origins,changedQueries=changed,scope='Exact full original static source and alpha; finite boat strip only replaced by its exact opaque along/Z silhouette on inverse-W authored line. Standing origin uses walkable detailed nav plus source floor within3cm; eye is actual matched source floor+1.75m. Horizontal standing rays only, not the experimental floor-following policy. Receiver is exact inverse-W union of attack/defense SVG fills. No candidate bake or production mutation.',productionMutation=False)
    (OUT/'boat-208-full-scene-standing-review.json').write_text(json.dumps(report,indent=2)+'\n');print(json.dumps(counts,indent=2))


if __name__=='__main__':main()

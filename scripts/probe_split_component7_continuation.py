"""Nearby source/nav standing layers and exact long-wall contacts, read only."""
import gzip,hashlib,json
import numpy as np
from pathlib import Path
from build_split_connected_tower import ROOT,REV
from native_reference_cast import NativeReferenceModel

def point_heights(triangles,point):
    a=triangles[:,0,:2];u=triangles[:,1,:2]-a;v=triangles[:,2,:2]-a;d=point-a;den=u[:,0]*v[:,1]-u[:,1]*v[:,0];valid=abs(den)>1e-12;b=np.zeros(len(a));c=b.copy();b[valid]=(d[valid,0]*v[valid,1]-d[valid,1]*v[valid,0])/den[valid];c[valid]=(u[valid,0]*d[valid,1]-u[valid,1]*d[valid,0])/den[valid];inside=valid&(b>=-1e-9)&(c>=-1e-9)&(b+c<=1+1e-9);ids=np.flatnonzero(inside);z=(1-b[ids]-c[ids])*triangles[ids,0,2]+b[ids]*triangles[ids,1,2]+c[ids]*triangles[ids,2,2];return ids,z

def main():
    out=REV/'split-component7-source-review-v1';catalog=json.loads((REV/'baseline-world/height_catalog.json').read_text())['maps']['split'];ui=catalog['uiTransform'];nav_path=REV/'baseline-world/split_navigation.json.gz';nav=json.loads(gzip.decompress(nav_path.read_bytes()));affine=np.array(json.loads((ROOT/'tactical-alignment-sides-v1/split.json').read_text())['nativeToAttackSvg']);inverse=np.linalg.inv(affine[:,:2])
    def native_vertices(values,scale):
        v=np.array(values,float).reshape(-1,3);uv=v[:,:2]/scale;v[:,0]=(uv[:,1]-ui['YScalarToAdd'])/(100*ui['YMultiplier']);v[:,1]=-(uv[:,0]-ui['XScalarToAdd'])/(100*ui['XMultiplier']);v[:,2]/=100;return v
    detail=nav['floorMesh'];dv=native_vertices(detail['vertices'],detail['coordinateScale']);dt=np.array(detail['triangles']).reshape(-1,4);valid=np.array(nav['walkable'])[dt[:,0]];dt=dt[valid];dtri=dv[dt[:,1:]]
    cv=native_vertices(nav['vertices'],nav['coordinateScale']);ct=np.array(nav['triangles']).reshape(-1,4);ct=ct[np.array(nav['walkable'])[ct[:,0]]];ctri=cv[ct[:,1:]]
    geom_path=ROOT/'supplemented-v2/world/split/geometry.npz';raw=np.load(geom_path);p,f=raw['points'],raw['faces'];meta=json.loads(geom_path.with_suffix('.json').read_text());bounds=np.array([o['boundsMeters'] for o in meta['objects']]);starts=np.array([o['firstFace'] for o in meta['objects']]);pack=REV/'full-height-input-v1/split/split.height.bin.gz';model=NativeReferenceModel(pack,REV/'native-tactical-rays-build/Release/tactical_reference_cast.dll');orig=np.load(pack.parent/'source-correspondence.npz')['sourceFaces'];rows=[]
    for svg in [[174,131],[174,133],[180,131],[180,133],[184,133],[180,138],[180,145],[190,131]]:
        xy=(np.array(svg)-affine[:,2])@inverse.T;di,dz=point_heights(dtri,xy);ci,cz=point_heights(ctri,xy);objects=np.flatnonzero((bounds[:,0,:2]<=xy+1e-8).all(1)&(bounds[:,1,:2]>=xy-1e-8).all(1));source_floors=[]
        for obj in objects:
            item=meta['objects'][obj];ids=np.arange(item['firstFace'],item['firstFace']+item['faceCount']);tri=p[f[ids]];hit,z=point_heights(tri,xy)
            for k,height in zip(hit,z):
                if len(dz) and np.min(abs(dz-height))<.05:source_floors.append(dict(originalFace=int(ids[k]),sourceObject=int(obj),path=item['path'],heightMeters=float(height),material=meta['materials'][int(raw['material_indices'][ids[k]])]))
        layers=[]
        for height in sorted(set(np.round(dz,8))):
            eye=float(height)+1.75;target=(np.array([svg[0],136 if svg[1]<132.359308 else 129])-affine[:,2])@inverse.T;hit=model.cast([*xy,eye],[*target,eye])
            if hit:
                source_id=int(orig[hit['face']]);obj=int(np.searchsorted(starts,source_id,side='right')-1);hit.update(originalFace=source_id,sourceObject=obj,path=meta['objects'][obj]['path'],material=meta['materials'][int(raw['material_indices'][source_id])],pointSvg=(np.array(hit['point'][:2])@affine[:,:2].T+affine[:,2]).tolist())
            layers.append(dict(sourceDetailedFloorMeters=float(height),standingEyeMeters=eye,rayTargetSvg=[svg[0],136 if svg[1]<132.359308 else 129],hit=hit))
        rows.append(dict(svg=svg,nativeXY=xy.tolist(),detailedFloorParents=dt[di,0].tolist(),detailedFloors=dz.tolist(),coarseNavParents=ct[ci,0].tolist(),coarseNavFloors=cz.tolist(),sourceFloorMatches=source_floors,layers=layers))
    report=dict(sourcePackSha256=hashlib.sha256(pack.read_bytes()).hexdigest(),navSha256=hashlib.sha256(nav_path.read_bytes()).hexdigest(),sourceGeometrySha256=hashlib.sha256(geom_path.read_bytes()).hexdigest(),scope='Exact source walkable detailed-floor positions with1.75m standing eye, plus original Recast coarse planes. Detailed floor is source-refined and not independent game walkability evidence; coarse Recast is independently extracted. Source floor candidates within5cm are reported as candidates, not newly admitted support.',rows=rows);(out/'continuation-standing-source-rays.json').write_text(json.dumps(report,indent=2));print([(r['svg'],r['detailedFloors'],[(q['standingEyeMeters'],None if q['hit'] is None else(q['hit']['sourceObject'],q['hit']['originalFace'])) for q in r['layers']]) for r in rows])

if __name__=='__main__':main()

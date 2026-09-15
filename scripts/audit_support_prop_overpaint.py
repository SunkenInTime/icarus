"""Measure retained prop support against actual detailed navigation footprints."""
import gzip,hashlib,json
from pathlib import Path
import numpy as np
import shapely

ROOT=Path('E:/IcarusWorldAudit/2026-09-06');REV=ROOT/'tactical-visibility-revision'
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def read(p):return json.loads(p.read_text())
def clipped_area(coords,plane,threshold):
 points=[np.array(p)for p in coords[:-1]];out=[]
 for a,b in zip(points,points[1:]+points[:1]):
  da=float(a@plane[:2]+plane[2]-threshold);db=float(b@plane[:2]+plane[2]-threshold)
  if da>=0:out.append(a)
  if (da>=0)!=(db>=0):out.append(a+(b-a)*da/(da-db))
 return shapely.Polygon(out).area if len(out)>=3 else 0.
def main():
 sp=REV/'source-floor-support-union-v4/icebox.floor-support.npz';support=np.load(sp);sourceids=support['sourceFaces'];tris=support['vertices'][support['triangles']]
 priorPath=REV/'floor-support-collision-audit-v1/icebox.json';prior=read(priorPath)
 navPath=REV/'baseline-world/icebox_navigation.json.gz';nav=json.loads(gzip.decompress(navPath.read_bytes()));ui=read(REV/'baseline-world/height_catalog.json')['maps']['icebox']['uiTransform'];d=nav['floorMesh'];v=np.array(d['vertices'],float).reshape(-1,3);uv=v[:,:2]/d['coordinateScale'];v[:,0]=(uv[:,1]-ui['YScalarToAdd'])/(100*ui['YMultiplier']);v[:,1]=-(uv[:,0]-ui['XScalarToAdd'])/(100*ui['XMultiplier']);v[:,2]/=100
 f=np.array(d['triangles']).reshape(-1,4);main=read(REV/'global-ground-v1/icebox.tactical-ground.json.gz') if False else json.loads(gzip.decompress((REV/'global-ground-v1/icebox.tactical-ground.json.gz').read_bytes()))
 valid=np.array(nav['walkable'])[f[:,0]]&(np.array(nav['components'])[f[:,0]]==main['mainComponent']);ft=v[f[valid,1:]];shapes=shapely.polygons(ft[:,:,:2]);tree=shapely.STRtree(shapes);planes=np.linalg.solve(np.concatenate([ft[:,:,:2],np.ones((len(ft),3,1))],2),ft[:,:,2,None])[:,:,0]
 selected=[r for r in prior['rows']if any(s in r['sourceObjectPath']for s in ['Snowman','Gravel','WarehouseFloorD','CautionTape_0_GroundA'])];results=[]
 for r in selected:
  si=np.flatnonzero(np.isin(sourceids,r['fullPackFaceIds']));metrics={'supportAreaM2':0.,'navOverlapAreaM2':0.,'above1mmAreaM2':0.,'above1cmAreaM2':0.,'above5cmAreaM2':0.,'maxHeightAboveNavM':None};extreme=None
  for i in si:
   t=tris[i];shape=shapely.Polygon(t[:,:2]);metrics['supportAreaM2']+=shape.area
   if shape.area<1e-12:continue
   plane=np.linalg.solve(np.column_stack([t[:,:2],np.ones(3)]),t[:,2])
   candidates=tree.query(shape,predicate='intersects');center=t.mean(0);order=sorted(candidates,key=lambda j:abs(center[2]-center[:2]@planes[j,:2]-planes[j,2]));remaining=shape
   for j in order:
    inter=remaining.intersection(shapes[j]);remaining=remaining.difference(shapes[j]);parts=list(inter.geoms)if hasattr(inter,'geoms')else[inter]
    for poly in parts:
     if poly.geom_type!='Polygon' or poly.area<1e-12:continue
     metrics['navOverlapAreaM2']+=poly.area;delta=plane-planes[j];coords=np.asarray(poly.exterior.coords);values=coords[:,:2]@delta[:2]+delta[2];maximum=float(values.max())
     if metrics['maxHeightAboveNavM'] is None or maximum>metrics['maxHeightAboveNavM']:
      metrics['maxHeightAboveNavM']=maximum;xy=coords[np.argmax(values),:2];extreme={'supportTriangle':int(i),'fullPackFace':int(sourceids[i]),'worldXY':xy.tolist(),'supportZ':float(xy@plane[:2]+plane[2]),'navigationZ':float(xy@planes[j,:2]+planes[j,2]),'navParent':int(f[valid][j,0])}
     for tol,key in [(.001,'above1mmAreaM2'),(.01,'above1cmAreaM2'),(.05,'above5cmAreaM2')]:metrics[key]+=clipped_area(coords,delta,tol)
  results.append({'sourceObjectPath':r['sourceObjectPath'],'sourceFirstFace':r['sourceFirstFace'],'v1AdmittedFaces':r['admittedFaces'],'v4AdmittedFaces':len(si),'classification':r['classification'],'metrics':metrics,'maximumExample':extreme,'fullPackFaceIds':sourceids[si].tolist()})
 report={'status':'read-only-diagnostic','policy':'Exact projected triangle intersections with detailed main-component navigation. When nav overlaps, assign coverage once to the plane closest to source triangle centroid first. Areas sum source surfaces, so overlapping prop layers can count twice. This measures geometric overpaint, not the final selected ray branch. Collision does not independently establish support classification.','evidence':[{'path':str(p),'sha256':sha(p)}for p in [sp,priorPath,navPath]],'rows':results}
 out=REV/'support-prop-overpaint-v4.json';out.write_text(json.dumps(report,indent=2));print(json.dumps([{k:r[k]for k in ['sourceObjectPath','v4AdmittedFaces','metrics']}for r in results],indent=2))
if __name__=='__main__':main()

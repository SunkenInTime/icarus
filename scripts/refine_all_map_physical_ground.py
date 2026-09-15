"""Refine continuous tactical ground with original-navigation physical floors.

Only named floor/ramp terrain on the main walkable navigation component enters
this overlay. Props remain separate selectable supports. The existing field is
the fallback, and none of these triangles becomes a visibility wall.
"""
import argparse
from collections import Counter, defaultdict
import gzip
import json
import numpy as np
import shapely
from shapely.affinity import affine_transform
from audit_all_map_gameplay_levels import OUT, ROOT, MAPS, read
from build_all_map_gameplay_supports import navigation_triangles, standing_obstacles
from compile_reviewed_svg_height_map import polygon
from gameplay_standing_volumes import StandingVolumes


def floor_role(path):
 label=path.split('/')[-2].lower()
 return any(s in label for s in ['floor','ground','ramp','stairs']) and not any(s in label for s in ['roof','ceiling','fan','alpha','leaf','leaves','paint','decal','tiretrack','floater','scatter','pebble','light','vista'])


def refine(name):
 directory=OUT/name;clearance=read(directory/'standing-clearance.json')
 main=Counter(r['navComponent'] for r in clearance['samples']).most_common(1)[0][0]
 groups=defaultdict(list)
 for r in clearance['samples']:
  if r['eligible'] and r['navComponent']==main and floor_role(r['sourcePath']):groups[r['standingCollision']].append(r)
 volumes=StandingVolumes(name);volume_ids={r['id']:i for i,r in enumerate(volumes.rows)};nav=navigation_triangles(name)
 overlays=[];evidence=[]
 for contact,samples in groups.items():
  index=volume_ids[contact];tri=volumes.triangles[index]
  normal=np.cross(tri[:,1]-tri[:,0],tri[:,2]-tri[:,0]);length=np.linalg.norm(normal,axis=1)
  # Original walking navigation corroborates each selected plane. Keep smooth
  # ramp collision as one plane rather than following decorative stair treads.
  selected=(abs(normal[:,2])>length*.8)&(length>1e-9)
  planes=defaultdict(list)
  for face in tri[selected]:
   plane=np.linalg.solve(np.c_[face[:,:2],np.ones(3)],face[:,2])
   planes[tuple(np.round(plane,7))].append(face)
  for key,faces in planes.items():
   plane=np.array(key)
   matched=[r for r in samples if abs(plane[:2]@r['nativeXY']+plane[2]-r['physicalFloorZ'])<1e-4]
   if not matched:continue
   ids=sorted(set(r['navTriangle'] for r in matched))
   domain=shapely.union_all(shapely.polygons(np.array(faces)[:,:,:2])).intersection(shapely.union_all(shapely.polygons(nav[ids,:,:2])).buffer(.42))
   if domain.is_empty:continue
   xy=shapely.get_coordinates(domain);z=xy@plane[:2]+plane[2];low,high=float(z.min()),float(z.max())
   # Only a convex floor body can safely ignore itself above its top plane.
   # For a sloped domain the height slab encloses every local standing capsule.
   ignored={index} if volumes.equations[index] is not None else set()
   capsule_lift=.42*(np.sqrt(1+float(plane[:2]@plane[:2]))-1)
   domain=domain.difference(standing_obstacles(volumes,domain,low+capsule_lift,ignored=ignored,height=1.96+high-low,floor_plane=plane))
   if domain.is_empty:continue
   faces=[]
   for p in shapely.get_parts(shapely.constrained_delaunay_triangles(domain)):
    if p.geom_type=='Polygon' and p.area>1e-12:
     xy=np.array(p.exterior.coords)[:3];faces.append(np.c_[xy,xy@plane[:2]+plane[2]])
   if not faces:continue
   faces=np.array(faces);overlays.append((high,faces))
   evidence.append(dict(collision=contact,nativePlane=plane.tolist(),navigationTriangles=ids,sourceObjects=sorted(set(r['sourceObject'] for r in matched)),samples=len(matched),nativeArea=float(domain.area),elevationRange=[low,high]))
 alignment=read(ROOT/f'tactical-alignment-sides-v1/{name}.json')
 # Ground is the lower passage at stacked floors. The support builder adds
 # the upper floor separately, allowing automatic top and manual ground.
 overlays.sort(key=lambda item:item[0]);native=np.concatenate([t for _,t in overlays]) if overlays else np.empty((0,3,3))
 for side in ['attack','defense']:
  before=read(directory/f'before-{side}.json.gz')
  path=directory/f'height-base-{side}.json.gz';model=read(path) if path.exists() else dict(before)
  matrix=np.array(alignment[f'nativeTo{side.title()}Svg']);tri=native.copy();tri[:,:,:2]=tri[:,:,:2]@matrix[:,:2].T+matrix[:,2]
  vertices=np.array(before['ground']['vertices']).reshape(-1,3);old=vertices[np.array(before['ground']['triangles']).reshape(-1,3)]
  combined=np.concatenate([tri,old]);unique,inverse=np.unique(combined.reshape(-1,3),axis=0,return_inverse=True)
  model['ground']=dict(vertices=unique.reshape(-1).tolist(),triangles=inverse.tolist())
  payload=gzip.compress(json.dumps(model,separators=(',',':'),allow_nan=False).encode(),mtime=0)
  path.write_bytes(payload);(directory/f'physical-ground-base-{side}.json.gz').write_bytes(payload)
 report=dict(map=name,mainNavigationComponent=main,overlays=len(overlays),addedGroundTriangles=len(native),evidence=evidence,
  reason='Original main-component navigation identifies connected floors. Exact local player collision planes replace interpolation there; decorative floor meshes, props, roofs and unconfirmed islands do not become primary ground. All prior ground remains as fallback.')
 (directory/'physical-ground-review.json').write_text(json.dumps(report,indent=2));print(name,len(overlays),'physical floor regions',len(native),'triangles',flush=True)


if __name__=='__main__':
 p=argparse.ArgumentParser();p.add_argument('maps',nargs='*',default=MAPS)
 for name in p.parse_args().maps:refine(name)

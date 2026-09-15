"""Keep Split's lower vent floor separate from the adjacent upper walkway."""
import gzip
import json
import numpy as np
import shapely
from shapely.affinity import affine_transform
from audit_all_map_gameplay_levels import OUT, ROOT, read
from build_all_map_gameplay_supports import navigation_triangles, standing_obstacles
from compile_reviewed_svg_height_map import polygon, rings
from gameplay_standing_volumes import StandingVolumes


def main():
 name='split';directory=OUT/name
 objects=read(ROOT/f'supplemented-v2/world/{name}/geometry.json')['objects']
 mesh=np.load(ROOT/f'supplemented-v2/world/{name}/geometry.npz')
 def faces(oid):
  o=objects[oid];return mesh['points'][mesh['faces'][o['firstFace']:o['firstFace']+o['faceCount']]].astype(float)
 lower=faces(7787);upper=faces(7786)
 floor=2.50000009
 low_domain=shapely.union_all(shapely.polygons(lower[:,:,:2]))
 upper_domain=shapely.union_all(shapely.polygons(upper[:,:,:2]))
 samples=[r for r in read(directory/'standing-clearance.json')['samples'] if r.get('sourceObject')==7787 and r['eligible']]
 assert len(samples)==36 and all(abs(r['physicalFloorZ']-floor)<1e-6 for r in samples)
 nav_ids=sorted(set(r['navTriangle'] for r in samples));nav=navigation_triangles(name)
 volumes=StandingVolumes(name)
 domain=low_domain.intersection(shapely.union_all(shapely.polygons(nav[nav_ids,:,:2])).buffer(.42)).difference(upper_domain)
 domain=domain.difference(standing_obstacles(volumes,domain,floor))
 alignment=read(ROOT/f'tactical-alignment-sides-v1/{name}.json');evidence=[]
 for side in ['attack','defense']:
  base=directory/f'physical-ground-base-{side}.json.gz'
  model=read(base if base.exists() else directory/f'before-{side}.json.gz');m=np.array(alignment[f'nativeTo{side.title()}Svg'])
  patch=affine_transform(domain,[*m[0,:2],*m[1,:2],*m[:,2]])
  patch=patch.intersection(shapely.union_all([polygon(r) for r in model['receiver']]))
  vertices=np.array(model['ground']['vertices']).reshape(-1,3);triangles=vertices[np.array(model['ground']['triangles']).reshape(-1,3)]
  result=[];changed=0
  for tri in triangles:
   shape=shapely.Polygon(tri[:,:2])
   if not shape.intersects(patch):result.append(tri);continue
   inside=shape.intersection(patch)
   if inside.area<1e-12:result.append(tri);continue
   plane=np.linalg.solve(np.c_[tri[:,:2],np.ones(3)],tri[:,2]);changed+=1
   for part,z in [(shape.difference(patch),None),(inside,floor)]:
    for face in shapely.get_parts(shapely.constrained_delaunay_triangles(part)):
     if face.geom_type!='Polygon' or face.area<1e-12:continue
     xy=np.array(face.exterior.coords)[:3];height=xy@plane[:2]+plane[2] if z is None else np.full(3,z)
     result.append(np.c_[xy,height])
  result=np.array(result)
  old_union=shapely.union_all(shapely.polygons(triangles[:,:,:2]));new_union=shapely.union_all(shapely.polygons(result[:,:,:2]))
  assert old_union.symmetric_difference(new_union).area<1e-7
  model['ground']=dict(vertices=result.reshape(-1).tolist(),triangles=np.arange(result.shape[0]*3).tolist())
  (directory/f'height-base-{side}.json.gz').write_bytes(gzip.compress(json.dumps(model,separators=(',',':'),allow_nan=False).encode(),mtime=0))
  evidence.append(dict(side=side,changedTriangles=changed,patchRings=[r for p in shapely.get_parts(patch) if p.geom_type=='Polygon' for r in rings(p)]))
 report=dict(map=name,sourceObjects=[7787,7786],sourcePaths=[objects[i]['path'] for i in [7787,7786]],floorElevationMeters=floor,originalNavigationTriangles=nav_ids,corroboratingSamples=len(samples),evidence=evidence,
  reason='The lower vent room is a physical 2.50 m floor beside the 6.50 m upper walkway. Old ground interpolation extended that upper elevation into the lower room. Preserve every upper-floor face and replace only the source-confirmed lower standing domain.')
 (directory/'lower-vent-ground-review.json').write_text(json.dumps(report,indent=2));print(name,len(samples),'lower vent floor samples',flush=True)


if __name__=='__main__':main()

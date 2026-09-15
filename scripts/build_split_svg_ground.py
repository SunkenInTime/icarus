"""Add source elevations without introducing any ground triangle as a blocker."""
import argparse,copy,gzip,json,math
from pathlib import Path
import numpy as np
import shapely
import xml.etree.ElementTree as ET
from svgpathtools import parse_path
from complete_split_svg_detail_heights import poly,rings,ROOT,REV
# Reviewed structural ground assemblies. Props, foliage, roofs and floor decals are excluded.
FLOORS=[5854,5861,5862,5864,5865,5922,5923,5924,5925,5930,6154,6155,6156,6157,6158,6171,6274,6347,6454,6456,6574,6712,6713,6714,6715,6945,6952,6959,7094,7221,7226,7327,7332,7429,7431,7433,7786,7787,7788,7893,7994,7995,7996,7997,7998]

def triangulated_parts(shape):
 for polygon in shapely.get_parts(shape):
  if polygon.geom_type!='Polygon' or polygon.area<1e-10:continue
  for triangle in shapely.get_parts(shapely.constrained_delaunay_triangles(polygon)):
   if triangle.area>1e-10 and polygon.covers(triangle.representative_point()):yield triangle

def replace_ground_footprint(points,faces,footprint,elevation):
 """Replace a false interpolated sheet inside one authored flat floor."""
 source=shapely.polygons(points[faces,:2]);domain=shapely.union_all(source)
 missing=footprint.difference(domain).area
 assert missing<1e-7,('Ground does not cover authored support',missing)
 affected=np.flatnonzero(shapely.intersects(source,footprint)&(shapely.area(shapely.intersection(source,footprint))>1e-10))
 affected_set=set(affected.tolist());vertices=points.tolist();outside=[]
 for i,ids in enumerate(faces):
  if i not in affected_set:outside.append(ids.tolist());continue
  triangle=points[ids];plane=np.linalg.solve(np.c_[triangle[:,:2],np.ones(3)],triangle[:,2])
  for piece in triangulated_parts(source[i].difference(footprint)):
   coords=np.asarray(piece.exterior.coords[:-1]);start=len(vertices)
   vertices.extend([[float(x),float(y),float(plane@np.array([x,y,1.]))] for x,y in coords])
   assert len(coords)==3
   outside.append([start,start+1,start+2])
 patch=[]
 for triangle in triangulated_parts(footprint):
  coords=np.asarray(triangle.exterior.coords[:-1]);start=len(vertices)
  vertices.extend([[float(x),float(y),float(elevation)] for x,y in coords])
  assert len(coords)==3
  patch.append([start,start+1,start+2])
 result_points=np.asarray(vertices);result_faces=np.asarray(patch+outside,dtype=int)
 result=shapely.polygons(result_points[result_faces,:2])
 assert abs(shapely.union_all(result).area-domain.area)<1e-7
 assert abs(shapely.area(shapely.intersection(result[:len(patch)],footprint)).sum()-footprint.area)<1e-7
 return result_points,result_faces,dict(replacedTriangles=len(affected),patchTriangles=len(patch),elevationMeters=elevation,footprintAreaSvg=footprint.area)

def main():
 ap=argparse.ArgumentParser(description=__doc__);ap.add_argument('--input',type=Path,required=True);ap.add_argument('--out',type=Path,required=True);args=ap.parse_args();args.out.mkdir(exist_ok=False)
 gp=REV/'global-ground-v1/split.tactical-ground.json.gz';field=json.loads(gzip.decompress(gp.read_bytes()));v=np.array(field['vertices']).reshape(-1,3);faces=np.array(field['triangles']).reshape(-1,3)
 rawpath=ROOT/'supplemented-v2/world/split/geometry.npz';raw=np.load(rawpath);meta=json.loads(rawpath.with_suffix('.json').read_text())['objects'];a=np.array(json.loads((ROOT/'tactical-alignment-sides-v1/split.json').read_text())['nativeToAttackSvg'])
 source=[];ids=[]
 for oid in FLOORS:
  o=meta[oid];fi=np.arange(o['firstFace'],o['firstFace']+o['faceCount']);t=raw['points'][raw['faces'][fi]].astype(float);n=np.cross(t[:,1]-t[:,0],t[:,2]-t[:,0]);length=np.linalg.norm(n,axis=1);keep=(n[:,2]>length*.65)&(length>1e-10);source.extend(t[keep]);ids.extend(fi[keep])
 source=np.array(source);ids=np.array(ids);polys=shapely.polygons(source[:,:,:2]);tree=shapely.STRtree(polys);planes=np.linalg.solve(np.concatenate([source[:,:,:2],np.ones((len(source),3,1))],axis=2),source[:,:,2,None])[:,:,0]
 original=v.copy();snaps=[]
 for i,p in enumerate(v):
  candidates=tree.query(shapely.Point(p[:2]),predicate='intersects')
  if not len(candidates):continue
  z=planes[candidates,:2]@p[:2]+planes[candidates,2];closest=int(np.argmin(abs(z-p[2])))
  if abs(z[closest]-p[2])>.4:continue
  v[i,2]=float(z[closest]);snaps.append(dict(vertex=i,rawFace=int(ids[candidates[closest]]),before=float(original[i,2]),after=float(v[i,2])))
 # The primary sheet remains single-valued and tactically continuous. Secondary
 # surfaces are explicit supports, rather than automatic highest-hit selection.
 expected_old={ 'box5803':0.,'b-north-box6694':4.,'b-south-box-stack6692-6693':3.,'mid-box7414':6.5,'b-pallet-cover6559':3.,'b-kingdom-stack1644-1645':4.,'b-tower-cover6834':9.}
 models={s:json.loads((args.input/f'split-{s}.json').read_text()) for s in ['attack','defense']};review=json.loads((args.input/'review-poses.json').read_text())
 source_input=all(m.get('version')==2 and m.get('verticalSpace')=='meters-source-elevation' for m in models.values())
 for side,m in models.items():
  m['version']=2;m['verticalSpace']='meters-source-elevation';points=v.copy();points[:,:2]=v[:,:2]@a[:,:2].T+a[:,2]
  if side=='defense':points[:,:2]=np.array([466.1762,473])-points[:,:2]
  if not source_input:
   for w in m['walls']:
    e=w.get('heightEvidence');e=e if isinstance(e,dict) else {}
    if 'floorElevationMeters' in e:floor=e['floorElevationMeters']
    elif 'localFloorZ' in e:floor=e['localFloorZ']
    elif 'sourceMaximumZ' in e:floor=e['sourceMaximumZ']-w['bands'][0][1]
    elif 'maximumSourceZ' in e:floor=e['maximumSourceZ']-w['bands'][0][1]
    elif w['id']=='box5803-wall-0':floor=0.
    elif w.get('sourcePathIndex')==5 and w['bands'] and w['bands'][0][1]<1:floor=3.
    elif not w['bands'] or w['id'].startswith('vent174'):floor=0.
    else:raise ValueError(('Missing wall floor evidence',w['id']))
    w['floorElevationMeters']=floor
   for s in m['supports']:
    selected=s.get('selectedSourceSupport');z=selected['z'] if selected else expected_old[s['id']]+s['heightAboveFloorMeters'];s.update(floorElevationMeters=z-s['heightAboveFloorMeters'],surfaceElevationMeters=z,label=s['id'].split('-box')[0].replace('-',' ').replace('box5803','A Site box').title())
  # Explicit top choices use literal SVG closed subpaths and measured source tops.
  elements=list(ET.parse(Path('assets/maps')/('split_map.svg' if side=='attack' else 'split_map_defense.svg')).getroot())
  for sid,label,path_index,match_bounds,objects,floor in ([] if source_input else [
   ('b-balcony','B Site balcony',16,[84,194,132,226],[6945],3.),
   ('a-site-sign','A Site sign',6,[434,151,443,168],[5825],0.),
   ('mid-double-stack','Mid crate stacks',9,[222,280,239,289],[3956,3957],4.5),
  ]):
   candidates=[]
   target=np.array(match_bounds,float)
   if side=='defense':target=np.r_[np.array([466.1762,473])-target[2:],np.array([466.1762,473])-target[:2]]
   for sub in parse_path(elements[path_index].get('d')).continuous_subpaths():
    pts=np.array([[seg.start.real,seg.start.imag] for seg in sub]+[[sub[-1].end.real,sub[-1].end.imag]])
    if len(pts)<3:continue
    p=shapely.Polygon(pts)
    if not p.is_valid or p.area<1:continue
    if max(abs(np.array(p.bounds)-target))<2:candidates.append(p)
   assert len(candidates)==1,(sid,side,len(candidates))
   source_z=max(float(np.array(meta[oid]['boundsMeters'])[1,2]) for oid in objects)
   # Verify an actual upward top face, rather than treating a bound as a support.
   flat_top=[]
   for oid in objects:
    o=meta[oid];fi=np.arange(o['firstFace'],o['firstFace']+o['faceCount']);t=raw['points'][raw['faces'][fi]].astype(float);n=np.cross(t[:,1]-t[:,0],t[:,2]-t[:,0]);good=(n[:,2]>np.linalg.norm(n,axis=1)*.95)&(np.ptp(t[:,:,2],axis=1)<.02)&(abs(t[:,:,2].mean(1)-source_z)<.06);flat_top.extend(fi[good].tolist())
   assert flat_top,(sid,'No source top')
   s=dict(id=sid,label=label,rings=rings(candidates[0]),fillRule='evenodd',heightAboveFloorMeters=source_z-floor,floorElevationMeters=floor,surfaceElevationMeters=source_z,sourceTopFaces=flat_top,sourceObjects=objects)
   m['supports'].append(s)
   center=candidates[0].representative_point();review['cases'].append(dict(id=f'{sid}-top-{side}',side=side,originSvg=[center.x,center.y],directionRadians=0 if side=='attack' else math.pi,rangeSvg=65,apertureRadians=math.radians(103),supportId=sid,description=label+' explicit top support'))
  # Rectangular cover supports are bounded by existing authored centerlines.
  for sid,label,b,oid,floor in ([] if source_input else [
   ('a-lobby-crate','A Lobby crate',[310.972,334.32,318.415,342.826],5952,3.),
   ('a-ramp-crate','A Ramp crate',[294.492,210.45,305.124,217.361],520,6.5),
   ('a-ramp-metal','A Ramp low crate',[294.492,206.197,299.276,210.45],5951,6.5),
   ('a-tower-crate','A Tower crate',[298.745,141.87,307.251,148.781],519,6.5),
   ('a-tower-metal','A Tower low crate',[298.745,148.781,306.719,153.034],5897,6.5),
   ('b-garage-crate','B Garage crate',[16.9806,237.563,24.4234,245.538],6561,3.),
  ]):
   o=meta[oid];fi=np.arange(o['firstFace'],o['firstFace']+o['faceCount']);t=raw['points'][raw['faces'][fi]].astype(float);n=np.cross(t[:,1]-t[:,0],t[:,2]-t[:,0]);top=float(t[:,:,2].max());good=(n[:,2]>np.linalg.norm(n,axis=1)*.95)&(np.ptp(t[:,:,2],axis=1)<.02)&(abs(t[:,:,2].mean(1)-top)<.06);assert good.any(),sid
   # Use the highest broad upward surface under the source object's center.
   center=(t[:,:,:2].min((0,1))+t[:,:,:2].max((0,1)))/2;hits=[]
   for fid,triangle in zip(fi[good],t[good]):
    try:uv=np.linalg.solve(np.column_stack((triangle[1,:2]-triangle[0,:2],triangle[2,:2]-triangle[0,:2])),center-triangle[0,:2])
    except np.linalg.LinAlgError:continue
    bary=np.r_[1-uv.sum(),uv]
    if bary.min()>=-1e-8:hits.append((float(bary@triangle[:,2]),int(fid)))
   assert hits,(sid,'No central source support')
   z,source_face=max(hits);b=np.array(b,float)
   if side=='defense':b=np.r_[np.array([466.1762,473])-b[2:],np.array([466.1762,473])-b[:2]]
   shape=shapely.box(*b);m['supports'].append(dict(id=sid,label=label,rings=rings(shape),fillRule='evenodd',heightAboveFloorMeters=z-floor,floorElevationMeters=floor,surfaceElevationMeters=z,sourceObjects=[oid],selectedSourceSupport=dict(rawFace=source_face,z=z,nativeXY=center.tolist())))
   c=shape.centroid;review['cases'].append(dict(id=f'{sid}-top-{side}',side=side,originSvg=[c.x,c.y],directionRadians=0 if side=='attack' else math.pi,rangeSvg=65,apertureRadians=math.radians(103),supportId=sid,description=label+' explicit top support'))
  balcony=next(s for s in m['supports'] if s['id']=='b-balcony')
  footprint=poly(balcony)
  points,ground_faces,correction=replace_ground_footprint(points,faces,footprint,balcony['surfaceElevationMeters'])
  m['ground']=dict(vertices=points.reshape(-1).tolist(),triangles=ground_faces.reshape(-1).tolist())
  m['groundEvidence']=dict(source=str(gp),sourceFloorGeometry=str(rawpath),sourceFloorObjects=FLOORS,sourceVertexSnaps=snaps,maximumSnapMeters=float(abs(v[:,2]-original[:,2]).max()),balconyPrimaryGroundCorrection=dict(**correction,supportId='b-balcony',sourceObject=6945,method='Existing ground triangles clipped at the authored SVG support footprint; the footprint is triangulated on the measured flat source top.'),policy='Primary connected navigation sheet with source-ground vertex corrections. The B balcony authored footprint replaces a false interpolation between B Site and B Tower with its measured flat source top. Interpolation across other ramps stays continuous; enclosed/secondary surfaces require an explicit support choice. Extension cells interpolate unanchored gaps and are not exact source floor proof.')
  (args.out/f'split-{side}.json').write_text(json.dumps(m,separators=(',',':')))
 for p in args.input.iterdir():
  if p.is_file() and p.name not in ['split-attack.json','split-defense.json','review-poses.json']:(args.out/p.name).write_bytes(p.read_bytes())
 (args.out/'review-poses.json').write_text(json.dumps(review));print(json.dumps(dict(sourceElevationInput=source_input,groundVertices=len(points),groundTriangles=len(ground_faces),snappedVertices=len(snaps),maximumSnapMeters=float(abs(v[:,2]-original[:,2]).max()))))
if __name__=='__main__':main()

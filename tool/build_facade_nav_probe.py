"""Freeze real standing nav poses facing an authored edge, then trace source hits."""
import argparse,gzip,json,math,sys
from pathlib import Path
import numpy as np
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'scripts'))
from audit_tactical_target_rays import ReferenceModel
from build_tactical_semantic_fixtures import floor_triangles,parent_height
from tactical_alignment_audit import vector_lines

def build(root,name,edge,output):
 rev=root/'tactical-visibility-revision';output.mkdir(parents=True,exist_ok=True)
 cat=json.loads((rev/'baseline-world/height_catalog.json').read_text())['maps'][name];nav=json.loads(gzip.decompress((rev/'baseline-world'/cat['navigation']).read_bytes()));t=cat['uiTransform'];v=np.asarray(nav['vertices'],float).reshape(-1,3);uv=v[:,:2]/nav['coordinateScale'];native=np.column_stack(((uv[:,1]-t['YScalarToAdd'])/(100*t['YMultiplier']),-(uv[:,0]-t['XScalarToAdd'])/(100*t['XMultiplier'])))
 projection=np.asarray(json.loads((root/f'tactical-alignment-sides-v1/{name}.json').read_text())['nativeToAttackSvg']);centers=np.array([native[p].mean(axis=0) for p in nav['polygons']]);svg=np.column_stack((centers,np.ones(len(centers))))@projection.T;a,b=vector_lines(Path(f'assets/maps/{name}_map.svg'))[edge];normal=np.array([-(b-a)[1],(b-a)[0]]);normal/=np.linalg.norm(normal);parents,tris=floor_triangles(nav,t);rows=[];seen=set();model=ReferenceModel(rev/f'full-height-input-v1/{name}/{name}.height.bin.gz');mapping=np.load(rev/f'full-height-input-v1/{name}/source-correspondence.npz')['sourceFaces'];world=next(r for r in json.loads((root/'completeness/combined-manifest-release-inputs-v2.json').read_text()) if r['map']==name);folder=Path(world['combinedWorldFolder']);meta=json.loads((folder/'geometry.json').read_text());geom=np.load(folder/'geometry.npz');sourcefaces=geom['faces'];sourcepoints=geom['points'];facts=[]
 for i,frac in enumerate([.1,.3,.5,.7,.9]):
  target=a+(b-a)*frac;choices=np.argsort(np.linalg.norm(svg-target,axis=1));parent=next(int(p) for p in choices if nav['walkable'][p] and int(p) not in seen);seen.add(parent);origin=centers[parent];floor=parent_height(parents,tris,parent,origin)
  if floor is None:raise ValueError(f'Missing detailed floor for parent{parent}')
  target_native=np.linalg.solve(projection[:,:2],target-projection[:,2]);d=target_native-origin;d/=np.linalg.norm(d);q=[*origin,floor+1.75,*d,25,103*math.pi/180];row={'id':f'edge{edge}-{i}-parent-{parent}','category':f'{name} authored edge{edge} actual nav pose','query':q,'originSvg':svg[parent].tolist(),'floorCm':floor*100,'parentPolygon':parent,'targetSvg':target.tolist()};rows.append(row);o=np.array(q[:3]);hit=model.cast(o,o+np.array([*d,0])*25)
  if hit:
   hsvg=np.r_[hit['point'][:2],1]@projection.T;sf=int(mapping[hit['face']]);obj=next(o for o in meta['objects'] if o['firstFace']<=sf<o['firstFace']+o['faceCount']);hit.update(hitSvg=hsvg.tolist(),signedDistanceFromAuthoredWallSvg=float((hsvg-a)@normal),sourceFace=sf,sourceObject=obj['path'],sourceTriangleMeters=sourcepoints[sourcefaces[sf]].tolist())
  facts.append({'id':row['id'],'sourceHorizontalHit':hit})
 (output/f'{name}-fixtures.json').write_text(json.dumps({'map':name,'navigationSha256':cat['navigationSha256'],'packSha256':cat['packSha256'],'policy':'Real nav poses facing authored wall. No expected answer imposed.','cases':rows},indent=2));(output/'source-horizontal-rays.json').write_text(json.dumps({'scope':'Independent source horizontal rays before flattening. First source object may be different from intended facade.','map':name,'svgLineId':edge,'targetLineSvg':[a.tolist(),b.tolist()],'cases':facts},indent=2));print(json.dumps(facts,indent=2))
if __name__=='__main__':
 p=argparse.ArgumentParser();p.add_argument('root',type=Path);p.add_argument('map');p.add_argument('edge',type=int);p.add_argument('output',type=Path);a=p.parse_args();build(a.root,a.map,a.edge,a.output)

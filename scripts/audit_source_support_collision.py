"""Classify admitted source support using serialized Pawn collision evidence."""
import argparse,hashlib,json,re,sys
from pathlib import Path
from functools import lru_cache
import numpy as np
sys.path.insert(0,str(Path(__file__).resolve().parent))
from audit_floor_pawn_support import classify_support

def main(root,name):
 rev=root/'tactical-visibility-revision';world=next(r for r in json.loads((root/'completeness/combined-manifest-release-inputs-v2.json').read_text())if r['map']==name);metaPath=Path(world['combinedWorldFolder'])/'geometry.json';meta=json.loads(metaPath.read_text());supportPath=rev/f'source-floor-support-union-v1/{name}.floor-support.npz';support=np.load(supportPath)['sourceFaces'];support=support[support>=0];mappingPath=rev/f'full-height-input-v1/{name}/source-correspondence.npz';mapping=np.load(mappingPath)['sourceFaces'];original=mapping[support];starts=np.array([o['firstFace']for o in meta['objects']]);objects=np.searchsorted(starts,original,side='right')-1;ids,counts=np.unique(objects,return_counts=True);meshroots=[root/'native-material-audit'/folder/'properties'for folder in ['mesh-export','extra-mesh-export','inherited-mesh-export']];rows=[];evidence={}
 def read(p):
  evidence[str(p)]=hashlib.sha256(p.read_bytes()).hexdigest();return json.loads(p.read_text())
 @lru_cache(maxsize=32)
 def leveldata(level):
  p=root/f'native-material-audit/resolved-component-export/properties/ShooterGame/Content/Maps/{level.split("_")[0]}/{level}.json';return read(p)if p.exists()else[]
 @lru_cache(maxsize=256)
 def meshbody(path):
  relative=Path('ShooterGame/Content')/(path.split('.')[0].removeprefix('/Game/')+'.json')
  for folder in meshroots:
   p=folder/relative
   if p.exists():
    bodies=[r for r in read(p)if r['Type']=='BodySetup'];return bodies[0].get('Properties',{})if len(bodies)==1 else{}
  return{}
 for i,count in zip(ids,counts):
  o=meta['objects'][i];level,sourceActor,*tail=o['path'].split('/');data=leveldata(level);actors=[r for r in data if r.get('ActorLabel')==sourceActor];actors=actors or[r for r in data if r.get('Name')==sourceActor and 'Component'not in r.get('Type','')];row={'sourceObjectPath':o['path'],'sourceFirstFace':o['firstFace'],'sourceFaceCount':o['faceCount'],'admittedFaces':int(count),'fullPackFaceIds':support[objects==i].tolist()}
  if len(actors)!=1:row.update(classification='unresolved-actor-match');rows.append(row);continue
  actor=actors[0];actual=actor['Name'];components=[r for r in data if 'StaticMeshComponent'in r.get('Type','')and f"PersistentLevel.{actual}'"in str(r.get('Outer'))];sourceName=re.sub(r'\.\d+$','',tail[-1]);exact=[r for r in components if r['Name']==sourceName]
  if len(exact)==1:components=exact
  if len(components)!=1:row.update(classification='unresolved-component-match');rows.append(row);continue
  comp=components[0];props=comp.get('Properties',{});mesh=(props.get('StaticMesh')or{}).get('ObjectPath');body=meshbody(mesh)if mesh else{};classification,basis,effective=classify_support(comp,body,actor);row.update(classification=classification,basis=basis,effectiveBody=effective,componentTemplate=comp.get('Template'),componentType=comp['Type'],nativeActor=actual,componentName=comp['Name'],meshPath=mesh,useDefaultCollision=props.get('bUseDefaultCollision'),meshCollisionTraceFlag=body.get('CollisionTraceFlag'),actorEnableCollision=actor.get('Properties',{}).get('bActorEnableCollision'))
  rows.append(row)
 summary={}
 for row in rows:
  key=row['classification'];item=summary.setdefault(key,{'placements':0,'faces':0});item['placements']+=1;item['faces']+=row['admittedFaces']
 out=rev/'floor-support-collision-audit-v1';out.mkdir(exist_ok=True);report={'schemaVersion':1,'map':name,'status':'read-only-support-collision-classification','policy':'Collision labels are not terrain decisions. Render floors may delegate gameplay collision to another mesh. Do not automatically exclude these rows from floor references; require separate source-floor correspondence or a proved effect exclusion. Missing inheritance stays unresolved.','sourceGeometrySha256':meta['geometrySha256'],'supportSha256':hashlib.sha256(supportPath.read_bytes()).hexdigest(),'sourceMappingSha256':hashlib.sha256(mappingPath.read_bytes()).hexdigest(),'evidence':[{'path':p,'sha256':sha}for p,sha in evidence.items()],'summary':summary,'rows':rows};(out/f'{name}.json').write_text(json.dumps(report,indent=2));print(summary)
 for row in rows:
  if row['classification'].startswith('excluded') and row['admittedFaces']>=200:print(row['admittedFaces'],row['sourceObjectPath'],row['classification'])
if __name__=='__main__':
 p=argparse.ArgumentParser();p.add_argument('root',type=Path);p.add_argument('map');a=p.parse_args();main(a.root,a.map)

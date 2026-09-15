"""Apply source-reviewed wall bands to a baseline or composed candidate root."""
import argparse,copy,gzip,hashlib,json
from pathlib import Path
import numpy as np
from shapely.affinity import affine_transform
from compile_reviewed_svg_height_map import polygon

REVIEW=Path('scripts/data/all-map-confirmed-wall-review-2026-09-14.json')
def sha(p):return hashlib.sha256(Path(p).read_bytes()).hexdigest()
def read(p):
 raw=Path(p).read_bytes();return json.loads(gzip.decompress(raw) if str(p).endswith('.gz') else raw)
def input_path(root,name,side):
 choices=[root/f'{name}_svg_height_{side}.json.gz',root/name/f'candidate-{side}.json.gz',root/name/f'{name}_svg_height_{side}.json.gz']
 found=[p for p in choices if p.exists()];assert len(found)==1,(name,side,'expected exactly one candidate input',found);return found[0]
def merge(bands,new):
 rows=sorted([list(map(float,b)) for b in bands]+[list(map(float,new))]);out=[]
 for lo,hi in rows:
  if out and lo<=out[-1][1]+1e-9:out[-1][1]=max(out[-1][1],hi)
  else:out.append([lo,hi])
 return out
def build(output,assets_dir,review_path=REVIEW):
 review=read(review_path);review_sha=sha(review_path)
 for e in review['evidence'].values():assert sha(e['path'])==e['sha256'],('evidence changed',e['path'])
 for e in review['sourceFiles'].values():assert sha(e['path'])==e['sha256'],('physical source changed',e['path'])
 prepared=[]
 for name,spec in review['maps'].items():
  assert sha(spec['alignment']['path'])==spec['alignment']['sha256'];a=read(spec['alignment']['path']);A=np.array(a['nativeToAttackSvg']);D=np.array(a['nativeToDefenseSvg']);linear=D[:,:2]@np.linalg.inv(A[:,:2]);offset=D[:,2]-linear@A[:,2];reflection=[*linear[0],*linear[1],*offset]
  for e in [spec['standingSource'],spec['standingAlignment']]:assert sha(e['path'])==e['sha256'],('standing source changed',e['path'])
  sides=[]
  for side in ['attack','defense']:
   p=input_path(assets_dir,name,side);model=read(p);assert model['map']==name and model['side']==side
   if assets_dir==Path('assets/maps'):assert sha(p)==spec['baselineSha256'][side],(name,side,'bundled baseline changed')
   sides.append((side,p,model,reflection))
  prepared.append((name,spec,sides))
 assert not output.exists(),'Choose a fresh output directory';output.mkdir(parents=True)
 results=[]
 for name,spec,sides in prepared:
  folder=output/name;folder.mkdir();side_results=[]
  attack_model=next(m for s,p,m,r in sides if s=='attack');attack={w['id']:w for w in attack_model['walls']}
  for op in spec['operations']:
   assert op['mode'] in {'union-band','remove-bands'},(name,op['id'],'unsupported mode')
   assert set(op['attackWallIds'])<=attack.keys(),(name,op['id'],'missing attack walls')
  for side,p,before,reflection in sides:
   model=copy.deepcopy(before);changed=[]
   for op in spec['operations']:
    attack_shapes=[polygon(attack[i]) for i in op['attackWallIds']]
    clips=[s if side=='attack' else affine_transform(s,reflection) for s in attack_shapes]
    matched=[];chosen={}
    for c in clips:
     distances=sorted((polygon(w).hausdorff_distance(c),i) for i,w in enumerate(model['walls']))
     assert distances[0][0]<.01,(name,side,op['id'],'no reflected authored cell',distances[0]);assert distances[0][1] not in chosen,(name,side,op['id'],'duplicate reflected cell')
     chosen[distances[0][1]]=distances[0][0]
    for wid in op.get('additionalWallIds',{}).get(side,[]):
     ids=[i for i,w in enumerate(model['walls']) if w['id']==wid];assert len(ids)==1,(name,side,op['id'],wid);chosen.setdefault(ids[0],0.)
    for i,w in enumerate(model['walls']):
     if i not in chosen:continue
     assert not w['unknownHeight'],(name,side,op['id'],w['id'],'cannot rewrite unresolved wall')
     old=copy.deepcopy(w['bands']);w['bands']=merge(old,op['bandMeters']) if op['mode']=='union-band' else []
     w['unknownHeight']=False;matched.append(w['id']);changed.append({'operation':op['id'],'wallId':w['id'],'reflectionHausdorffSvg':chosen[i],'beforeBands':old,'afterBands':w['bands']})
    assert len(matched)>=len(clips),(name,side,op['id'],len(matched),len(clips))
   assert all(model[k]==before[k] for k in before if k!='walls')
   for x,y in zip(model['walls'],before['walls']):assert {k:v for k,v in x.items() if k in ('id','rings','fillRule','floorElevationMeters')}=={k:v for k,v in y.items() if k in ('id','rings','fillRule','floorElevationMeters')}
   from restore_exposed_standing_floors import restore_exposed_floors
   restored=restore_exposed_floors(name,before,model,read(spec['standingSource']['path']),read(spec['standingAlignment']['path'])[f'nativeTo{side.title()}Svg'])
   model['sourceConfirmedWallReviewSha256']=review_sha
   target=folder/f'candidate-{side}.json.gz';target.write_bytes(gzip.compress(json.dumps(model,separators=(',',':'),allow_nan=False).encode(),mtime=0));side_results.append({'side':side,'input':str(p),'inputSha256':sha(p),'outputSha256':sha(target),'changed':changed,'restoredStandingDomains':restored})
  results.append({'map':name,'sides':side_results})
 app={'reviewSha256':review_sha,'algorithmSha256':sha(__file__),'maps':results};(output/'application.json').write_text(json.dumps(app,indent=2)+'\n');return app
if __name__=='__main__':
 p=argparse.ArgumentParser();p.add_argument('--output',type=Path,required=True);p.add_argument('--assets-dir',type=Path,default=Path('assets/maps'));p.add_argument('--review',type=Path,default=REVIEW);a=p.parse_args();print(json.dumps(build(a.output,a.assets_dir,a.review)))

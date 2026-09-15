"""Resolve the bounded related-plane audit without modifying source packs."""
import hashlib,json,re
from pathlib import Path
import numpy as np
from audit_tactical_target_rays import ReferenceModel

ROOT=Path('E:/IcarusWorldAudit/2026-09-06'); REV=ROOT/'tactical-visibility-revision'
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def read(p):return json.loads(p.read_text(encoding='utf-8-sig'))
def main():
 out=REV/'related-effects-audited-exclusions-v1';out.mkdir(exist_ok=True)
 baseline=read(ROOT/'native-material-audit/resolved-component-export/extraction-audit.json'); materials={}; evidence=[]
 for folder in ['related-effects-material-export-v1','related-effects-parent-export-v1']:
  audit=REV/folder/'extraction-audit.json'; a=read(audit)
  assert a['archives']==baseline['archives'] and a['mapping']==baseline['mapping']
  evidence.append(audit)
  for f in (REV/folder/'properties').rglob('*.json'):
   rows=read(f); r=rows[0]; materials[r['Package']]=(r,f)
 summary=[]
 for name in ['icebox','corrode']:
  prior=read(REV/f'floor-support-audited-exclusions-v2/{name}.json')
  w=next(w for w in read(ROOT/'completeness/combined-manifest-release-inputs-v2.json')if w['map']==name)
  metaPath=Path(w['combinedWorldFolder'])/'geometry.json';meta=read(metaPath)
  fullpath=REV/f'full-height-input-v1/{name}/source-correspondence.npz';full=np.load(fullpath)['sourceFaces']
  oldpath=ROOT/f'compact-prototype/all-map-height-scoped-v2/{name}/source-correspondence.npz';old=np.load(oldpath)['sourceFaces']
  sp=REV/f'source-floor-support-union-v1/{name}.floor-support.npz';support=np.load(sp)['sourceFaces'] if sp.exists()else np.array([],int)
  pack=ReferenceModel(REV/f'full-height-input-v1/{name}/{name}.height.bin.gz')
  sources=[*evidence,metaPath,fullpath,oldpath]; rows=[]
  for flag in prior['flaggedUnclassified']:
   path=flag['path'];o=next(o for o in meta['objects']if o['path']==path)
   level,actor,component=path.split('/')[:3];pf=ROOT/f'native-material-audit/resolved-component-export/properties/ShooterGame/Content/Maps/{level.split("_")[0]}/{level}.json';data=read(pf)
   names=[r['Name'] for r in data if r.get('ActorLabel')==actor];actor=names[0] if len(names)==1 else actor
   cs=[r for r in data if r.get('Type')=='StaticMeshComponent' and r['Name']==re.sub(r'\.\d+$','',component) and f"PersistentLevel.{actor}'"in str(r.get('Outer'))]
   assert len(cs)==1,(path,len(cs));c=cs[0];p=c['Properties'];body=p['BodyInstance']
   assert c.get('Template') is None and p.get('bUseDefaultCollision') is False
   assert body['CollisionEnabled']=='ECollisionEnabled::NoCollision' and body['CollisionProfileName']=='NoCollision'
   assert p['StaticMesh']['ObjectPath']=='/Game/Environment/Port/VFX/WindStreaks/WindStreaks_Plane.2'
   assert len(p['OverrideMaterials'])==1
   current=re.sub(r'\.\d+$','',p['OverrideMaterials'][0]['ObjectPath']);chain=[];refs=[]
   while current:
    m,mf=materials[current]; mp=m['Properties'];chain.append({'package':current,'type':m['Type'],'blend':mp.get('BlendMode',mp.get('BasePropertyOverrides',{}).get('BlendMode')),'shading':mp.get('ShadingModel',mp.get('BasePropertyOverrides',{}).get('ShadingModel'))});refs.append(mf)
    current=re.sub(r'\.\d+$','',mp.get('Parent',{}).get('ObjectPath',''))
   assert chain[-1]['type']=='Material'
   assert all(r['shading']=='EMaterialShadingModel::MSM_Unlit' for r in chain)
   assert all(r['blend'] in ['EBlendMode::BLEND_TranslucentGreyTransmittance','EBlendMode::BLEND_Additive'] for r in chain)
   frost=any('/ColdMist/'in r['package'] for r in chain)
   ids=np.flatnonzero((full>=o['firstFace'])&(full<o['firstFace']+o['faceCount']));oi=np.flatnonzero((old>=o['firstFace'])&(old<o['firstFace']+o['faceCount']))
   row={'sourceObjectPath':path,'sourceFirstFace':o['firstFace'],'sourceFaceCount':o['faceCount'],'fullPackFaceIds':ids.tolist(),'originalSourceFaceIds':full[ids].tolist(),'frozenVisibilityPackFaceIds':oi.tolist(),'admittedSupportFullPackFaceIds':np.intersect1d(ids,support).tolist(),'materialChain':chain,'componentTemplate':None,'collision':body,'supportDecision':'exclude-from-standing-support','visibilityDecision':'unresolved-optical-obscuration'if frost else'exclude-from-structural-occlusion','basis':'Explicit noncolliding component carrying a translucent/additive unlit effect plane. Frost opacity remains unresolved.'if frost else'Explicit noncolliding effect plane and complete translucent/additive unlit material chain.','evidence':[str(pf),*[str(f)for f in refs]]}
   rows.append(row);sources.extend([pf,*refs])
  report={'schemaVersion':1,'map':name,'status':'bounded-audited-effect-source-exclusions','productionMutation':False,'sourceGeometrySha256':meta['geometrySha256'],'fullHeightSourcePackSha256':prior['fullHeightSourcePackSha256'],'policy':'Only the 93 preselected identical plane placements are classified. NoCollision alone is not an exclusion for real render floors. Frost glass is excluded only as standing support; its visibility is unresolved.','evidence':[{'path':str(f),'sha256':sha(f)}for f in dict.fromkeys(sources)],'rows':rows}
  (out/f'{name}.json').write_text(json.dumps(report,indent=2))
  summary.append({'map':name,'placements':len(rows),'fullFaces':sum(len(r['fullPackFaceIds'])for r in rows),'visibilityExcludedFaces':sum(len(r['fullPackFaceIds'])for r in rows if r['visibilityDecision']=='exclude-from-structural-occlusion'),'unresolvedVisibilityFaces':sum(len(r['fullPackFaceIds'])for r in rows if r['visibilityDecision'].startswith('unresolved')),'oldFaces':sum(len(r['frozenVisibilityPackFaceIds'])for r in rows),'seededSupportFaces':sum(len(r['admittedSupportFullPackFaceIds'])for r in rows)})
 (out/'summary.json').write_text(json.dumps(summary,indent=2));print(json.dumps(summary,indent=2))
if __name__=='__main__':main()

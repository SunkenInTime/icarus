"""Audit exact WindStreak template/material chain against full source face IDs.

Names select candidates for inspection only. An exclusion requires matching the
serialized component template, mesh, dynamic-material parent and its proof.
"""
import argparse,hashlib,json,re
from pathlib import Path
import numpy as np

def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def main(root):
 rev=root/'tactical-visibility-revision';out=rev/'floor-support-audited-exclusions-v2';out.mkdir(exist_ok=True);proof=rev/'floor-support-effect-export-v1/properties/ShooterGame/Content/Environment/Port/VFX/WindStreaks';bp=proof/'WindStreaks_BP.json';mi=proof/'WindStreaks_Inst.json';template=next(r for r in json.loads(bp.read_text())if r['Name']=='StaticMesh_GEN_VARIABLE');material=json.loads(mi.read_text())[0];assert template['Properties']['BodyInstance']['CollisionEnabled']=='ECollisionEnabled::NoCollision';assert material['Properties']['BasePropertyOverrides']['BlendMode']=='EBlendMode::BLEND_TranslucentGreyTransmittance';assert material['Properties']['BasePropertyOverrides']['ShadingModel']=='EMaterialShadingModel::MSM_Unlit';summary=[]
 # Discover candidates by serialized mesh/template references across all level
 # exports, including arbitrary actor labels. Names are only extra review hints.
 native_prefixes=set(); inspected_packages=0
 for prop in (root/'native-material-audit/resolved-component-export/properties/ShooterGame/Content/Maps').rglob('*.json'):
  data=json.loads(prop.read_text()); inspected_packages+=1; labels={r.get('Name'):r.get('ActorLabel',r.get('Name')) for r in data if 'ActorLabel'in r}
  for c in data:
   if c.get('Type')!='StaticMeshComponent':continue
   if (c.get('Properties',{}).get('StaticMesh') or {}).get('ObjectPath')!='/Game/Environment/Port/VFX/WindStreaks/WindStreaks_Plane.2' and (c.get('Template') or {}).get('ObjectPath')!='/Game/Environment/Port/VFX/WindStreaks/WindStreaks_BP.6':continue
   match=re.search(r"PersistentLevel\.([^']+)'",str(c.get('Outer',{}).get('ObjectName','')))
   if match:
    actor=match.group(1);native_prefixes.add(prop.stem+'/'+actor);native_prefixes.add(prop.stem+'/'+labels.get(actor,actor))
 worlds=json.loads((root/'completeness/combined-manifest-release-inputs-v2.json').read_text())
 for world in worlds:
  name=world['map'];metaFile=Path(world['combinedWorldFolder'])/'geometry.json';meta=json.loads(metaFile.read_text());candidates=[o for o in meta['objects']if '/'.join(o['path'].split('/')[:2]) in native_prefixes or 'WindStreak' in o['path']];rows=[];flagged=[];sources=[bp,mi,metaFile]
  if candidates:
   fullPath=rev/f'full-height-input-v1/{name}/source-correspondence.npz';full=np.load(fullPath)['sourceFaces'];oldPath=root/f'compact-prototype/all-map-height-scoped-v2/{name}/source-correspondence.npz';old=np.load(oldPath)['sourceFaces'];sources +=[fullPath,oldPath];supportPath=rev/f'source-floor-support-union-v1/{name}.floor-support.npz';support=np.load(supportPath)['sourceFaces'] if supportPath.exists()else np.array([],dtype=int)
   for o in candidates:
    level,actor,*_=o['path'].split('/');propFile=root/f'native-material-audit/resolved-component-export/properties/ShooterGame/Content/Maps/{level.split("_")[0]}/{level}.json'
    if not propFile.exists():flagged.append({'path':o['path'],'reason':'serialized level unavailable'});continue
    data=json.loads(propFile.read_text());actor_matches=[r['Name'] for r in data if r.get('ActorLabel')==actor];actor=actor_matches[0] if len(actor_matches)==1 else actor;components=[r for r in data if r.get('Type')=='StaticMeshComponent'and r.get('Name')=='StaticMesh'and f"PersistentLevel.{actor}'" in str(r.get('Outer'))]
    if len(components)!=1:flagged.append({'path':o['path'],'reason':'component match ambiguous'});continue
    c=components[0];p=c['Properties'];refs=(c.get('Template') or {}).get('ObjectPath');mesh=p.get('StaticMesh',{}).get('ObjectPath');body=p.get('BodyInstance',{});override=p.get('OverrideMaterials',[]);dynamic=[r for r in data if r.get('Type')=='MaterialInstanceDynamic'and f"PersistentLevel.{actor}.StaticMesh'" in str(r.get('Outer'))]
    if refs!='/Game/Environment/Port/VFX/WindStreaks/WindStreaks_BP.6'or mesh!='/Game/Environment/Port/VFX/WindStreaks/WindStreaks_Plane.2'or len(dynamic)!=1 or dynamic[0].get('Properties',{}).get('Parent',{}).get('ObjectPath')!='/Game/Environment/Port/VFX/WindStreaks/WindStreaks_Inst.0'or set(body)-{'MaxAngularVelocity'}or p.get('bUseDefaultCollision')is True:
     flagged.append({'path':o['path'],'reason':'exact proof chain differs'});continue
    # Require the component's assigned material to be the proved dynamic child.
    if len(override)!=1 or f"PersistentLevel.{actor}.StaticMesh.MaterialInstanceDynamic_0'"not in override[0].get('ObjectName',''):
     flagged.append({'path':o['path'],'reason':'material assignment differs'});continue
    sources.append(propFile);ids=np.flatnonzero((full>=o['firstFace'])&(full<o['firstFace']+o['faceCount']));oldIds=np.flatnonzero((old>=o['firstFace'])&(old<o['firstFace']+o['faceCount']));rows.append({'sourceObjectPath':o['path'],'sourceFirstFace':o['firstFace'],'sourceFaceCount':o['faceCount'],'fullPackFaceIds':ids.tolist(),'originalSourceFaceIds':full[ids].tolist(),'frozenVisibilityPackFaceIds':oldIds.tolist(),'admittedSupportFullPackFaceIds':np.intersect1d(ids,support).tolist(),'supportDecision':'exclude-from-standing-support','visibilityDecision':'exclude-from-structural-occlusion','basis':'Verified inherited NoCollision component and assigned translucent/unlit dynamic material parent.'})
  for flag in flagged:
   matches=[o for o in candidates if o['path']==flag['path']]
   flag['fullPackFaceIds']=[int(i) for o in matches for i in np.flatnonzero((full>=o['firstFace'])&(full<o['firstFace']+o['faceCount']))]
   flag['status']='unclassified-no-exclusion'
  report={'schemaVersion':1,'map':name,'status':'audited-effect-source-exclusions','productionMutation':False,'sourceGeometrySha256':meta['geometrySha256'],'fullHeightSourcePackSha256':sha(rev/f'full-height-input-v1/{name}/{name}.height.bin.gz'),'evidence':[{'path':str(p),'sha256':sha(p)}for p in dict.fromkeys(sources)],'discovery':{'nativeLevelPackagesScanned':inspected_packages,'matchedSourcePrefixes':sorted(native_prefixes)},'inheritanceRule':'Placed BodyInstance only overrides MaxAngularVelocity; inherited NoCollision remains. Mesh default BlockAll is not selected.','rows':rows,'flaggedUnclassified':flagged};(out/f'{name}.json').write_text(json.dumps(report,indent=2));summary.append({'map':name,'provedPlacements':len(rows),'fullFaces':sum(len(r['fullPackFaceIds'])for r in rows),'oldFaces':sum(len(r['frozenVisibilityPackFaceIds'])for r in rows),'supportFaces':sum(len(r['admittedSupportFullPackFaceIds'])for r in rows),'flagged':len(flagged)})
 (out/'summary.json').write_text(json.dumps(summary,indent=2));print(json.dumps(summary,indent=2))
if __name__=='__main__':
 p=argparse.ArgumentParser();p.add_argument('root',type=Path);main(p.parse_args().root)

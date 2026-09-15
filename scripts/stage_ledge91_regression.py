import json,gzip,hashlib
from pathlib import Path
import numpy as np
from tactical_alignment_composite import IndexedTriangles
from build_global_tactical_candidate import GroundField
R=Path('E:/IcarusWorldAudit/2026-09-06/tactical-visibility-revision');w=json.loads(gzip.decompress((R/'display-warps-v1/split.display-warp.json.gz').read_bytes()));s=np.array(w['sourceNativeMeters']).reshape(-1,2);t=np.array(w['targetAttackSvg']).reshape(-1,2);ids=np.array(w['triangles']).reshape(-1,3);tri=IndexedTriangles(t,ids)
def inv(p):
 p=np.array(p);cell=tri.find_simplex(p[None])[0];tr=tri.transform[cell];uv=tr[:2]@(p-tr[2]);return np.r_[uv,1-uv.sum()]@s[ids[cell]]
start=[361.755,233.184];contact=[357.755,229.184];a=inv(start);b=inv(contact);heading=(b-a)/np.linalg.norm(b-a);q=[*a,1.75,*heading,15.,1.7976891295541595];config=json.loads((R/'gallery-connected-tower-v14-fixtures/candidate-config-v15.json').read_text());field=GroundField(config['maps']['split']['groundFieldFile']);ground=float(field.heights(a[None])[0]);fixtures=json.loads((R/'gallery-connected-tower-v14/split-fixtures.json').read_text());id='91-restored-ledge-standing';fixtures['cases']=[dict(id=id,category='Standing source-ray regression for restored low ledge90',query=[*a,ground+1.75,*heading,15.,1.7976891295541595],originSvg=start,sourceDirectedTargetSvg=contact,targetSvg=contact,eyeHeightMode='absolute',expectedAuthoredSpan=[[357.755,231.184],[357.755,213.64]],sourceRayKey=[91,0,2.,-4.,1.75])]
for version,pack in [('original',R/'global-ground-complete-v2/split'),('v14',R/'split-wall-family-normalized-candidate-v14'),('v15',R/'split-wall-family-normalized-candidate-v15')]:
 D=R/f'gallery-ledge91-{version}';D.mkdir(exist_ok=True);c=json.loads(json.dumps(config));entry=c['maps']['split'];entry['folder']=str(pack/'native');entry['candidatePackSha256']=hashlib.sha256((pack/'split.height.bin.gz').read_bytes()).hexdigest();entry['queriesById']={id:q};entry['scopeLabel']=f'{version} restored ledge regression';c['scope']='Frozen source standing cone. No nav reachability or all-map acceptance.';(D/'candidate-config.json').write_text(json.dumps(c,indent=2));(D/'split-fixtures.json').write_text(json.dumps(fixtures,indent=2))
print('query',q,'source ground',ground)

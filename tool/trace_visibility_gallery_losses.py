"""Trace changed masked directions to source objects for fixed gallery poses."""
import argparse,json,math,sys
from pathlib import Path
import numpy as np
from PIL import Image
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'scripts'))
from audit_tactical_target_rays import ReferenceModel
from build_global_tactical_candidate import GroundField

def main(root,name,ids):
 rev=root/'tactical-visibility-revision';gallery=rev/'gallery-all-map-lower-provisional-v1'
 cases=[c for c in json.loads((gallery/'manifest.json').read_text())['cases'] if c['map']==name and c['side']=='attack' and c['id'] in ids]
 before=ReferenceModel(rev/'baseline-world'/f'{name}.height.bin.gz');after=ReferenceModel(rev/'global-ground-complete-v2'/name/f'{name}.height.bin.gz')
 field=GroundField(rev/'global-ground-v1'/f'{name}.tactical-ground.json.gz')
 cutmap=np.load(rev/'global-ground-complete-v2'/name/'correspondence.npz')['sourceFaces'];fullmap=np.load(rev/'full-height-input-v1'/name/'source-correspondence.npz')['sourceFaces']
 world=next(r for r in json.loads((root/'completeness/combined-manifest-release-inputs-v2.json').read_text()) if r['map']==name);folder=Path(world['combinedWorldFolder']);meta=json.loads((folder/'geometry.json').read_text()); geometry=np.load(folder/'geometry.npz');faces=geometry['faces'];vertices=geometry['points']
 output=[]
 for case in cases:
  q=np.array(case['query']);cq=np.array(case['candidateQuery']);angle=math.atan2(q[4],q[3]);proj=np.array(case['candidateProjectionRows']);bm=np.asarray(Image.open(case['before'].replace('-overlay.png','-visibility.png')).getchannel('A'));am=np.asarray(Image.open(case['after'].replace('-overlay.png','-visibility.png')).getchannel('A'));rows=[]
  for i,theta in enumerate(np.linspace(angle-q[6]/2,angle+q[6]/2,129)):
   d=np.array([math.cos(theta),math.sin(theta),0]);bh=before.cast(q[:3],q[:3]+d*q[5]);ah=after.cast(cq[:3],cq[:3]+d*cq[5]);bd=q[5] if bh is None else bh['distanceMeters'];ad=cq[5] if ah is None else ah['distanceMeters']
   if bd-ad<.15 or ah is None:continue
   visible=[]
   for t in np.linspace(ad+.03,bd-.03,40):
    pos=cq[:2]+d[:2]*t;svg=np.r_[pos,1]@proj.T;px=np.floor(svg*2).astype(int)
    if 0<=px[0]<bm.shape[1] and 0<=px[1]<bm.shape[0] and bm[px[1],px[0]]>=128 and am[px[1],px[0]]<128:visible.append(float(t))
   if not visible:continue
   sf=int(fullmap[cutmap[ah['face']]]);obj=next(o for o in meta['objects'] if o['firstFace']<=sf<o['firstFace']+o['faceCount']);tri=vertices[faces[sf]];normal=np.cross(tri[1]-tri[0],tri[2]-tri[0]);normal/=np.linalg.norm(normal);point=np.array(ah['point']);point[2]+=field.heights(point[None,:2])[0]
   rows.append({'directionIndex':i,'direction':d.tolist(),'beforeDistanceMeters':bd,'afterDistanceMeters':ad,'maskedLostIntervalMeters':[min(visible),max(visible)],'sourceFace':sf,'sourceObject':obj['path'],'sourceTriangleMeters':tri.tolist(),'sourceNormal':normal.tolist(),'sourceHitMeters':point.tolist()})
  output.append({'id':case['id'],'query':case['query'],'candidateQuery':case['candidateQuery'],'lostDirections':rows})
 report={'scope':'Direct independent casts in original and transformed geometry. Only directions with actual lost SVG receiver pixels are included. This diagnoses changed blockers, not whether tactical semantics are desirable.','map':name,'cases':output};dest=gallery/f'{name}-lost-source-directions.json';dest.write_text(json.dumps(report,indent=2));print(dest)
 for row in output:
  groups={}
  for r in row['lostDirections']:groups.setdefault(r['sourceObject'],[]).append(r)
  print(row['id'],[(k,len(v),round(max(r['beforeDistanceMeters']-r['afterDistanceMeters'] for r in v),2),v[0]['sourceNormal']) for k,v in groups.items()])
if __name__=='__main__':
 p=argparse.ArgumentParser();p.add_argument('root',type=Path);p.add_argument('map');p.add_argument('ids',nargs='+');a=p.parse_args();main(a.root,a.map,a.ids)

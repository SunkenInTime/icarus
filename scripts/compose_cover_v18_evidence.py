"""Native-pixel V17/V18 cover evidence with unchanged physical queries."""
import json,gzip,hashlib
from pathlib import Path
import numpy as np
from PIL import Image,ImageDraw,ImageFont
from tactical_alignment_composite import IndexedTriangles
R=Path('E:/IcarusWorldAudit/2026-09-06/tactical-visibility-revision');before=R/'cover-contact-v17';after=R/'cover-contact-v18';output=R/'cover-v17-v18-evidence';output.mkdir(exist_ok=True);versions=[('V17 prior candidate',before),('V18 connected cover',after)];manifests=[json.loads((p/'manifest.json').read_text()) for _,p in versions];indices=[{(r['id'],r['side']):r for r in m['cases']} for m in manifests];w=json.loads(gzip.decompress(Path(manifests[1]['displayWarpFile']).read_bytes()));native=np.array(w['sourceNativeMeters']).reshape(-1,2);display=np.array(w['targetAttackSvg']).reshape(-1,2);cells=np.array(w['triangles']).reshape(-1,3);tri=IndexedTriangles(native,cells);cases={c['id']:c for c in json.loads((R/'gallery-cover-v18/split-fixtures.json').read_text())['cases']};font=ImageFont.truetype('C:/Windows/Fonts/segoeui.ttf',14);small=ImageFont.truetype('C:/Windows/Fonts/segoeui.ttf',12);records=[]
for key,row in indices[-1].items():
 id,side=key;old=indices[0][key];assert old['query']==row['query'] and old['svgSha256']==row['svgSha256'];case=cases[id];center=np.array(case['sourceDirectedTargetSvg']);eye=case['controlRelativeEyeMeters'];origin=np.array(row['query'][:2]);cell=tri.find_simplex(origin[None])[0];t=tri.transform[cell];uv=t[:2]@(origin-t[2]);o=np.r_[uv,1-uv.sum()]@display[cells[cell]]
 focus=np.array([center-[8,8],center+[8,8]])
 images=[Image.open(p/f'{side}-{id}-8x-overlay.png').convert('RGB') for _,p in versions];arrays=[np.asarray(im) for im in images];changed=int(np.any(arrays[0]!=arrays[1],axis=2).sum())
 for kind,rect in [('focus',focus),('context',np.array([[409,127],[434,152]]))]:
  if side=='defense':rect=np.array(w['attackToDefenseSvg']['origin'])-rect
  box=tuple(map(int,np.r_[np.floor(rect.min(0)*8),np.ceil(rect.max(0)*8)]));width=max(355,box[2]-box[0]);height=box[3]-box[1];im=Image.new('RGB',(2*(width+16)+16,height+120),'#18181c');d=ImageDraw.Draw(im);sources=[]
  for i,((label,p),source) in enumerate(zip(versions,images)):
   im.paste(source.crop(box),(16+i*(width+16),60));d.text((16+i*(width+16),35),label,font=font,fill='white');path=p/f'{side}-{id}-8x-overlay.png';sources.append(dict(path=str(path),sha256=hashlib.sha256(path.read_bytes()).hexdigest()))
   if kind=='context':
    oo=o if side=='attack' else np.array(w['attackToDefenseSvg']['origin'])-o;px=oo*8-np.array(box[:2])+[16+i*(width+16),60];d.line((px[0]-5,px[1],px[0]+5,px[1]),fill='white',width=1);d.line((px[0],px[1]-5,px[0],px[1]+5),fill='white',width=1);d.text((px[0]+7,px[1]-15),'Origin',font=small,fill='white')
  d.text((16,8),f'Split / {side} / {id} / {kind} / native8x',font=font,fill='white');d.text((16,height+75),f'Control-relative eye {eye:g} m; source-field normalization. This is not constant absolute Z.',font=small,fill='#d0d0d4');d.text((16,height+94),'Diagnostic source poses; no reachable-position claim. Original pixels, unchanged physical query.',font=small,fill='#ffcc82');path=output/f'{side}-{id}-{kind}-native8x.png';im.save(path);records.append(dict(id=id,side=side,kind=kind,image=str(path),sha256=hashlib.sha256(path.read_bytes()).hexdigest(),cropPixels=box,controlRelativeEyeMeters=eye,sourceQuery=row['query'],sourceGroundAtOriginMeters=case['sourceGroundAtOriginMeters'],absoluteSourceEye=case['physicalSourceEye'],changedFullOverlayPixels=changed,sourceImages=sources))
(output/'manifest.json').write_text(json.dumps(dict(scope=__doc__,sourceManifests=[dict(path=str(p/'manifest.json'),sha256=hashlib.sha256((p/'manifest.json').read_bytes()).hexdigest()) for _,p in versions],records=records),indent=2));print('Wrote',len(records),'evidence views');print([(r['id'],r['side'],r['changedFullOverlayPixels']) for r in records if r['kind']=='focus' and r['side']=='attack'])

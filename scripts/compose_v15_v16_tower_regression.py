import json,gzip,hashlib
from pathlib import Path
import numpy as np
from PIL import Image,ImageDraw,ImageFont
from tactical_alignment_composite import IndexedTriangles
R=Path('E:/IcarusWorldAudit/2026-09-06/tactical-visibility-revision');after=R/'tower-v16-regression-contact';M=json.loads((after/'manifest.json').read_text());w=json.loads(gzip.decompress(Path(M['displayWarpFile']).read_bytes()));source=np.array(w['sourceNativeMeters']).reshape(-1,2);target=np.array(w['targetAttackSvg']).reshape(-1,2);idx=np.array(w['triangles']).reshape(-1,3);tri=IndexedTriangles(source,idx);cases={c['id']:c for c in json.loads((R/'gallery-tower-v16-regression/split-fixtures.json').read_text())['cases']};out=R/'tower-v15-v16-regression-evidence';out.mkdir(exist_ok=True);font=ImageFont.truetype('C:/Windows/Fonts/segoeui.ttf',14);small=ImageFont.truetype('C:/Windows/Fonts/segoeui.ttf',12);records=[]
for row in M['cases']:
 id,side=row['id'],row['side'];before=R/'tower-v16-regression-contact-v15-control';bm=json.loads((before/'manifest.json').read_text());br=next(r for r in bm['cases'] if r['id']==id and r['side']==side);assert br['query']==row['query'];c=cases[id];center=np.array(c.get('targetSvg',c.get('sourceDirectedTargetSvg',np.mean(c['expectedAuthoredSpan'],axis=0))));p=np.array(row['query'][:2]);cell=tri.find_simplex(p[None])[0];t=tri.transform[cell];uv=t[:2]@(p-t[2]);origin=np.r_[uv,1-uv.sum()]@target[idx[cell]]
 for kind,rect in [('focus',np.array([center-[14,11],center+[14,11]])),('context',np.array([[300,140],[386,242]]))]:
  if side=='defense':rect=np.array(w['attackToDefenseSvg']['origin'])-rect
  box=tuple(np.r_[np.floor(rect.min(0)*8),np.ceil(rect.max(0)*8)].astype(int));width=max(320,box[2]-box[0]);height=box[3]-box[1];im=Image.new('RGB',(2*(width+16)+16,height+116),'#18181c');d=ImageDraw.Draw(im);sources=[];o=origin if side=='attack' else np.array(w['attackToDefenseSvg']['origin'])-origin
  for i,(label,folder) in enumerate([('V15 prior candidate',before),('V16 connected attachment',after)]):
   path=folder/f'{side}-{id}-8x-overlay.png';crop=Image.open(path).convert('RGB').crop(box);im.paste(crop,(16+i*(width+16),60));d.text((16+i*(width+16),34),label,font=font,fill='white');sources.append(dict(path=str(path),sha256=hashlib.sha256(path.read_bytes()).hexdigest()))
   if kind=='context':
    px=o*8-np.array(box[:2])+[16+i*(width+16),60];d.line((px[0]-6,px[1],px[0]+6,px[1]),fill='white',width=1);d.line((px[0],px[1]-6,px[0],px[1]+6),fill='white',width=1);d.text((px[0]+8,px[1]-15),'Origin',font=small,fill='white')
  d.text((16,8),f'Split / {side} / {id} / {kind} / native8x',font=font,fill='white');d.text((16,height+74),'Same physical source pose. Original pixels; no resampling.',font=small,fill='#d0d0d4');d.text((16,height+92),'Diagnostic candidate. Source-relative floor policy remains provisional.',font=small,fill='#ffcc82');path=out/f'{side}-{id}-{kind}-native8x.png';im.save(path);a=np.array(Image.open(sources[0]['path']));b=np.array(Image.open(sources[1]['path']));records.append(dict(id=id,side=side,kind=kind,image=str(path),sourceImages=sources,sourceQuery=row['query'],originSvg=o.tolist(),cropPixels=list(map(int,box)),changedFullOverlayPixels=int(np.any(a!=b,axis=2).sum())))
(out/'manifest.json').write_text(json.dumps(dict(records=records,displayWarpSha256=M['displayWarpSha256']),indent=2));print([(r['id'],r['side'],r['changedFullOverlayPixels']) for r in records if r['kind']=='focus'])



import json,gzip,hashlib
from pathlib import Path
import numpy as np
from PIL import Image,ImageDraw,ImageFont
from audit_wall_contact_pixels import PhysicalGeometry
from native_reference_cast import NativeReferenceModel
R=Path('E:/IcarusWorldAudit/2026-09-06/tactical-visibility-revision');id='91-restored-ledge-standing';versions=['original','v14','v15'];folders=[R/f'ledge91-contact-{v}' for v in versions];ms=[json.loads((p/'manifest.json').read_text()) for p in folders];w=json.loads(gzip.decompress(Path(ms[-1]['displayWarpFile']).read_bytes()));D=R/'ledge91-standing-regression-evidence';D.mkdir(exist_ok=True);font=ImageFont.truetype('C:/Windows/Fonts/segoeui.ttf',14);small=ImageFont.truetype('C:/Windows/Fonts/segoeui.ttf',12);rows=[]
# Target is between the restored ledge hit and authored91, safely within the receiver.
attack_target=np.array([358.1875,229.6875]);origin=np.array([361.755,233.184]);rayTarget=[355.755,227.184]
for side in ['attack','defense']:
 rr=[next(r for r in m['cases'] if r['side']==side) for m in ms];assert rr[0]['query']==rr[1]['query']==rr[2]['query'];target=attack_target if side=='attack' else np.array(w['attackToDefenseSvg']['origin'])-attack_target;alphas={};hits={};centerline_hits={}
 for version,folder,m,row in zip(versions,folders,ms,rr):
  g=PhysicalGeometry(w,row,np.fromfile(row['prefix']+'-shadow.f32',dtype='<f4'));point=g.native(target)[0];pack=(R/'global-ground-complete-v2/split' if version=='original' else R/f'split-wall-family-normalized-candidate-{version}')/'split.height.bin.gz';native=NativeReferenceModel(pack,R/'native-tactical-rays-build/Release/tactical_reference_cast.dll');hit=native.cast(row['query'][:3],np.r_[point,1.75]);hits[version]=hit;centerline_contact=g.native(np.array([357.755,229.184]) if side=='attack' else np.array(w['attackToDefenseSvg']['origin'])-np.array([357.755,229.184]))[0];centerline_end=np.array(row['query'][:2])+1.5*(centerline_contact-np.array(row['query'][:2]));centerline_hits[version]=native.cast(row['query'][:3],np.r_[centerline_end,1.75])
  for scale in [2,8]:
   alpha=np.array(Image.open(folder/f'{side}-{id}-{scale}x-visibility.png'))[:,:,3];xy=np.floor(target*scale).astype(int);alphas[f'{version}-{scale}x']=int(alpha[xy[1],xy[0]])
 assert hits['original'] is not None and hits['v14'] is None and hits['v15'] is not None,hits
 assert centerline_hits['original'] is not None and centerline_hits['v14'] is None and centerline_hits['v15'] is not None,centerline_hits
 assert alphas['v14-8x']>=200 and alphas['original-8x']==0 and alphas['v15-8x']==0,alphas
 for kind,rect in [('focus',np.array([[352,224],[368,237]])),('context',np.array([[340,208],[378,242]]))]:
  if side=='defense':rect=np.array(w['attackToDefenseSvg']['origin'])-rect
  box=tuple(map(int,np.r_[np.floor(rect.min(0)*8),np.ceil(rect.max(0)*8)]));width=max(300,box[2]-box[0]);height=box[3]-box[1];im=Image.new('RGB',(3*(width+16)+16,height+119),'#18181c');d=ImageDraw.Draw(im);sources=[]
  for i,(v,f) in enumerate(zip(versions,folders)):
   p=f/f'{side}-{id}-8x-overlay.png';im.paste(Image.open(p).convert('RGB').crop(box),(16+i*(width+16),60));d.text((16+i*(width+16),34),{'original':'Original source','v14':'V14 missing ledge','v15':'V15 restored ledge'}[v],font=font,fill='white');sources.append(dict(path=str(p),sha256=hashlib.sha256(p.read_bytes()).hexdigest()))
   if kind=='context':
    o=origin if side=='attack' else np.array(w['attackToDefenseSvg']['origin'])-origin;px=o*8-np.array(box[:2])+[16+i*(width+16),60];d.line((px[0]-5,px[1],px[0]+5,px[1]),fill='white',width=1);d.line((px[0],px[1]-5,px[0],px[1]+5),fill='white',width=1);d.text((px[0]+7,px[1]-15),'Origin',font=small,fill='white')
  d.text((16,8),f'Split / {side} / restored ledge91 source-ray regression / {kind} / native8x',font=font,fill='white');d.text((16,height+74),'Identical standing source eye, heading,15m range and103-degree FOV. Original pixels; no resampling.',font=small,fill='#d0d0d4');d.text((16,height+93),'Bounded source preservation check. Floor policy and adjacent wall roles remain provisional.',font=small,fill='#ffcc82');p=D/f'{side}-{kind}-native8x.png';im.save(p);rows.append(dict(side=side,kind=kind,image=str(p),sha256=hashlib.sha256(p.read_bytes()).hexdigest(),sources=sources,query=rr[0]['query'],targetSvg=target.tolist(),targetAlphas=alphas,nativeHits=hits,centerlineHits=centerline_hits,cropPixels=box))
(D/'regression.json').write_text(json.dumps(dict(scope='Original/V15 block the frozen standing ray and actual receiver pixel;V14 was incorrectly clear. No fullmap acceptance.',passed=True,sourceManifests=[dict(path=str(f/'manifest.json'),sha256=hashlib.sha256((f/'manifest.json').read_bytes()).hexdigest()) for f in folders],rows=rows),indent=2));print([(r['side'],r['targetAlphas']) for r in rows if r['kind']=='focus'])


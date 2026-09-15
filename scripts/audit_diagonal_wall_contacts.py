"""Native-pixel diagonal evidence with independent source-mesh contact samples."""
import argparse
import gzip
import hashlib
import json
from pathlib import Path

import numpy as np
from PIL import Image,ImageDraw,ImageFont

from audit_wall_contact_pixels import PhysicalGeometry


def measure(folder,row,warp,span,inward):
    mesh=Path(row['prefix']+'-shadow.f32').read_bytes()
    assert hashlib.sha256(mesh).hexdigest()==row['meshSha256']
    g=PhysicalGeometry(warp,row,np.frombuffer(mesh,dtype='<f4'))
    length=np.linalg.norm(span[1]-span[0]);along=np.linspace(0,length,int(np.ceil(length/.05))+1)
    points=span[0]+along[:,None]*(span[1]-span[0])/length
    admitted=g.in_frustum(points)
    offset=np.arange(-1.5,5.001,.005)
    clear=g.clear((points[:,None]+offset[None,:,None]*inward).reshape(-1,2)).reshape(len(points),-1)
    samples=[]
    for t,p,a,c in zip(along,points,admitted,clear):
        if a:samples.append(dict(alongSvg=float(t),pointSvg=p.tolist(),firstClearInwardSvg=float(offset[np.flatnonzero(c)[0]]) if c.any() else None))
    values=[x['firstClearInwardSvg'] for x in samples if x['firstClearInwardSvg'] is not None]
    return dict(samples=samples,excludedByRangeOrFov=int((~admitted).sum()),
                geometricStepSvg=.005,alongStepSvg=float(along[1]-along[0]),
                offsetRange=[min(values),max(values)] if values else [None,None],
                unresolvedSamples=sum(x['firstClearInwardSvg'] is None or abs(x['firstClearInwardSvg'])>.01 for x in samples))


def run(before,after,fixtures):
    a=json.loads((before/'manifest.json').read_text());b=json.loads((after/'manifest.json').read_text())
    old={(r['id'],r['side']):r for r in a['cases']};f={r['id']:r for r in json.loads(fixtures.read_text())['cases']}
    warp=json.loads(gzip.decompress(Path(b['displayWarpFile']).read_bytes()));out=[]
    font=ImageFont.truetype('C:/Windows/Fonts/segoeui.ttf',14)
    for row in b['cases']:
        prior=old[row['id'],row['side']];assert prior['query']==row['query']
        span=np.array(f[row['id']]['expectedAuthoredSpan']);tangent=span[1]-span[0];normal=np.array([-tangent[1],tangent[0]])/np.linalg.norm(tangent)
        observer=np.array(f[row['id']]['originSvg']);normal*=1 if (observer-span.mean(0))@normal>0 else -1
        if row['side']=='defense':span=np.array(warp['attackToDefenseSvg']['origin'])-span;normal=-normal
        metrics=[measure(before,prior,warp,span,normal),measure(after,row,warp,span,normal)]
        lo=np.floor(span.min(0)*8).astype(int)-48;hi=np.ceil(span.max(0)*8).astype(int)+49;box=tuple(int(x) for x in [*lo,*hi]);width=max(400,box[2]-box[0]);height=box[3]-box[1]
        image=Image.new('RGB',(width*2+48,height+142),'#18181c');sources=[]
        for i,folder in enumerate([before,after]):
            path=folder/f"{row['side']}-{row['id']}-8x-overlay.png";image.paste(Image.open(path).convert('RGB').crop(box),(16+i*(width+16),65));sources.append(dict(path=str(path),sha256=hashlib.sha256(path.read_bytes()).hexdigest()))
        d=ImageDraw.Draw(image);d.text((16,8),f"{row['id']} | {row['side']} | native8x | same physical source pose",font=font,fill='white')
        for i,(label,m) in enumerate(zip(['Original source','Isolated diagonal candidate'],metrics)):
            x=16+i*(width+16);d.text((x,36),label,font=font,fill='white');d.text((x,height+78),f"Sampled inward stop: {m['offsetRange'][0]:+.3f} .. {m['offsetRange'][1]:+.3f} SVG",font=font,fill='white')
        d.text((16,height+108),'Adjacent returns and floor semantics remain provisional. No resampling.',font=font,fill='#ffcc82')
        path=after/f"{row['side']}-{row['id']}-diagonal-native8x.png";image.save(path)
        out.append(dict(id=row['id'],side=row['side'],spanSvg=span.tolist(),normal=normal.tolist(),before=metrics[0],after=metrics[1],sourceImages=sources,image=str(path),imageSha256=hashlib.sha256(path.read_bytes()).hexdigest(),cropPixels=list(box)))
        print(row['id'],row['side'],'before',metrics[0]['offsetRange'],'after',metrics[1]['offsetRange'],'unresolved',metrics[1]['unresolvedSamples'])
    (after/'diagonal-contact-report.json').write_text(json.dumps(dict(scope=__doc__,limitation='Geometry samples and untouched raster crops. No axis-aligned blank-band metric is applied to diagonal AA; this is not an all-rays or whole-map certificate.',records=out),indent=2))


if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('before',type=Path);p.add_argument('after',type=Path);p.add_argument('fixtures',type=Path);a=p.parse_args();run(a.before,a.after,a.fixtures)

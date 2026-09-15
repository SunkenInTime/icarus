"""Actual native-pixel tower comparisons; no interpolation, dilation or wall-role inference."""
import argparse
import gzip
import hashlib
import json
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw, ImageFont

REV=Path('E:/IcarusWorldAudit/2026-09-06/tactical-visibility-revision')


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def run(mode):
    if mode=='diagonal':
        versions=[('Original source',REV/'diagonal-contact-split-baseline-v1'),
                  ('Prior isolated diagonal',REV/'diagonal-contact-split-candidate-v1'),
                  ('V14 connected tower',REV/'tower-diagonal84-contact-v14')]
        fixtures=REV/'gallery-tower-diagonal84-v14/split-fixtures.json'
    else:
        versions=[('Original source',REV/'tower-contact-original-control'),
                  ('V14 connected tower',REV/'tower-contact-v14')]
        fixtures=REV/'gallery-connected-tower-v14/split-fixtures.json'
    manifests=[json.loads((p/'manifest.json').read_text()) for _,p in versions]
    rows=[{(r['side'],r['id']):r for r in m['cases']} for m in manifests]
    warp=json.loads(gzip.decompress(Path(manifests[-1]['displayWarpFile']).read_bytes()))
    cases={c['id']:c for c in json.loads(fixtures.read_text())['cases']}
    output=REV/f'tower-v14-{mode}-evidence'
    output.mkdir(exist_ok=True)
    records=[]
    font=ImageFont.truetype('C:/Windows/Fonts/segoeui.ttf',15)
    small=ImageFont.truetype('C:/Windows/Fonts/segoeui.ttf',13)
    for key,row in rows[-1].items():
        side,id=key
        for prior in rows:
            assert prior[key]['query']==row['query'] and prior[key]['svgSha256']==row['svgSha256']
        case=cases[id]
        if mode=='diagonal':
            span=np.array(case['expectedAuthoredSpan'])
            focus=np.array([span.min(0)-6,span.max(0)+6])
        else:
            target=np.array(case['targetSvg'])
            focus=np.array([target-[14,11],target+[14,11]])
        for kind,rect in [('focus',focus),('context',np.array([[300.,140.],[386.,242.]]))]:
            if side=='defense':
                rect=np.array(warp['attackToDefenseSvg']['origin'])-rect
            box=tuple(int(v) for v in np.r_[np.floor(rect.min(0)*8),np.ceil(rect.max(0)*8)])
            width=max(300,box[2]-box[0]);height=box[3]-box[1]
            canvas=Image.new('RGB',(len(versions)*(width+16)+16,height+122),'#18181c')
            sources=[]
            for i,((label,folder),manifest) in enumerate(zip(versions,manifests)):
                p=folder/f'{side}-{id}-8x-overlay.png'
                canvas.paste(Image.open(p).convert('RGB').crop(box),(16+i*(width+16),65))
                sources.append(dict(label=label,path=str(p),sha256=sha(p),manifestSha256=sha(folder/'manifest.json'),
                                    nativePackSha256=manifest.get('declaredCandidatePackSha256')))
            d=ImageDraw.Draw(canvas)
            d.text((16,8),f'Split / {side} / {id} | {kind} | native8x, same physical source pose',font=font,fill='white')
            for i,(label,_) in enumerate(versions):
                d.text((16+i*(width+16),36),label,font=font,fill='white')
            d.text((16,height+78),'Diagnostic only. Standing control eye1.75m; source gaps, corner precision and floor semantics remain under review.',font=small,fill='#ffcc82')
            d.text((16,height+99),'Unscaled original pixels. Surrounding structures retain their actual candidate behavior.',font=small,fill='#c8c8cc')
            p=output/f'{side}-{id}-{kind}-native8x.png'
            canvas.save(p)
            records.append(dict(side=side,id=id,kind=kind,image=str(p),sha256=sha(p),sourceImages=sources,
                                cropPixels=box,sourceQuery=row['query'],svgSha256=row['svgSha256']))
    (output/'manifest.json').write_text(json.dumps(dict(scope=__doc__,fixturesSha256=sha(fixtures),
                                                       displayWarpSha256=manifests[-1]['displayWarpSha256'],records=records),indent=2))
    print('Wrote',len(records),'native-pixel comparisons to',output)


if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('mode',choices=['diagonal','connected'])
    run(p.parse_args().mode)

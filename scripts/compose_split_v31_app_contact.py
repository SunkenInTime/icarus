"""Compare the exact changed pixels of the frozen ten-agent application scene."""
import argparse
import json
from pathlib import Path
import numpy as np
from PIL import Image,ImageDraw,ImageFont
from native_compact_wall_profiles import sha


def main():
    r=Path('E:/IcarusWorldAudit/2026-09-06/tactical-visibility-revision')
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--before',type=Path,default=r/'frozen-split-app-scene-v30-run1')
    parser.add_argument('--after',type=Path,default=r/'frozen-split-app-scene-v31-run1')
    parser.add_argument('--out',type=Path,default=r/'frozen-split-app-v30-v31-contact-review')
    args=parser.parse_args();folders=[args.before,args.after];out=args.out;out.mkdir(exist_ok=False)
    manifests=[json.loads((f/'manifest.json').read_text()) for f in folders];assert manifests[0]['frozenFrame']==manifests[1]['frozenFrame'];assert manifests[0]['displayWarpSha256']==manifests[1]['displayWarpSha256']
    records=[];font=ImageFont.truetype('C:/Windows/Fonts/segoeui.ttf',15);small=ImageFont.truetype('C:/Windows/Fonts/segoeui.ttf',12)
    for side in ['attack','defense']:
        rows=[next(row for row in m['records'] if row['side']==side and 'native8x' in row['image']) for m in manifests];assert rows[0]['sourceQueries']==rows[1]['sourceQueries']
        paths=[Path(row['image']) for row in rows];images=[Image.open(p).convert('RGBA') for p in paths];arrays=[np.asarray(im) for im in images];mask=np.any(arrays[0]!=arrays[1],axis=2);ys,xs=np.nonzero(mask)
        if not len(xs):
            records.append(dict(side=side,changedPixels=0,sourceQueriesUnchanged=True))
            continue
        bounds=[int(xs.min()),int(ys.min()),int(xs.max())+1,int(ys.max())+1];box=[bounds[0]-16,bounds[1]-16,bounds[2]+16,bounds[3]+16]
        crops=[im.crop(box).convert('RGB') for im in images];width,height=crops[0].size;canvas=Image.new('RGB',(width*2+48,height+104),'#18181b')
        for i,crop in enumerate(crops):canvas.paste(crop,(16+i*(width+16),63))
        draw=ImageDraw.Draw(canvas);draw.text((16,9),f'{side.title()} | Frozen app scene | Original native 8x pixels',font=font,fill='white')
        for i,label in enumerate(['Before','After']):draw.text((16+i*(width+16),39),label,font=small,fill='white')
        draw.text((16,height+76),'Exact same frame and queries. Crop includes every changed pixel. Ramps and other unreviewed corners remain provisional.',font=small,fill='#efc485')
        path=out/f'{side}-changed-wall-native8x.png';canvas.save(path)
        records.append(dict(side=side,changedPixels=int(mask.sum()),changedBoundsPixels=bounds,cropPixels=box,comparison=str(path),comparisonSha256=sha(path),
            sources=[dict(path=str(p),sha256=sha(p)) for p in paths],sourceQueriesUnchanged=True,allPixelChangesInsideCrop=True))
    (out/'report.json').write_text(json.dumps(dict(records=records,scope=__doc__,noResampling=True,
        sourceManifests=[dict(path=str(f/'manifest.json'),sha256=sha(f/'manifest.json')) for f in folders]),indent=2)+'\n');print(json.dumps(records,indent=2))


if __name__=='__main__':main()

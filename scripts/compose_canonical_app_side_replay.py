"""Compare actual app widget captures at native pixels after a side flip."""
import hashlib
import json
import sys
from pathlib import Path

import numpy as np
from PIL import Image,ImageDraw,ImageFont

ROOT=Path(sys.argv[1]) if len(sys.argv)>1 else Path('E:/IcarusWorldAudit/2026-09-06/tactical-visibility-revision/app-canonical-side-replay-v2')


def run():
    manifest=json.loads((ROOT/'manifest.json').read_text())
    records=[]
    for name in ['split','icebox','lotus']:
        rows=[r for r in manifest['records'] if r['map']==name and r['density']==8]
        a=next(r for r in rows if r['side']=='attack');b=next(r for r in rows if r['side']=='defense')
        assert a['canonicalOrigin']==b['canonicalOrigin'] and a['canonicalRotation']==b['canonicalRotation']
        delta=np.array(b['query'])-a['query'];assert max(abs(delta))<1e-9
        images=[];boxes=[]
        for r in [a,b]:
            im=Image.open(r['image']).convert('RGB');scale=r['viewport'][1]*r['pixelRatio']/1000
            center=np.array(r['canonicalOrigin'])*scale
            if r['side']=='defense':
                physical=(np.array([1000*16/9,1000])-r['canonicalOrigin'])*scale
                im=im.transpose(Image.Transpose.ROTATE_180)
                center=np.array([im.width-1,im.height-1])-physical
            c=np.floor(center).astype(int);box=[int(c[0]-280),int(c[1]-360),int(c[0]+280),int(c[1]+360)]
            images.append(im.crop(box));boxes.append(box)
        out=Image.new('RGB',(1168,828),'#18181c')
        for i,im in enumerate(images):out.paste(im,(16+576*i,72))
        d=ImageDraw.Draw(out);font=ImageFont.truetype('C:/Windows/Fonts/segoeui.ttf',15)
        d.text((16,10),f'{name.upper()} | actual CanonicalMapArtwork + HeightViewCone | same saved marker and heading',font=font,fill='white')
        d.text((16,42),'Attack. Native 8 physical pixels per SVG unit.',font=font,fill='white')
        d.text((592,42),'Defense. Pixels rotated180; no scaling/resampling.',font=font,fill='white')
        d.text((16,800),'Side-registration control only. Source geometry and floor policy remain provisional.',font=font,fill='#ffcc82')
        path=ROOT/f'{name}-app-side-pair-native8x.png';out.save(path)
        records.append(dict(map=name,image=str(path),imageSha256=hashlib.sha256(path.read_bytes()).hexdigest(),
                            queryDelta=delta.tolist(),sameSourceMeshHash=a['sourceMeshSha256']==b['sourceMeshSha256'],
                            cropPixels=boxes,sourceImages=[a['image'],b['image']]))
        print(name,'maxQueryDelta',max(abs(delta)),'sameMeshHash',records[-1]['sameSourceMeshHash'])
    code=['lib/widgets/canonical_map_artwork.dart','lib/const/map_artwork_registration.dart',
          'lib/widgets/draggable_widgets/utilities/height_view_cone.dart','tool/export_canonical_side_app_test.dart']
    (ROOT/'side-pair-evidence.json').write_text(json.dumps(dict(scope=__doc__,records=records,
          inspectedCodeSha256={p:hashlib.sha256(Path(p).read_bytes()).hexdigest() for p in code}),indent=2))


if __name__=='__main__':run()

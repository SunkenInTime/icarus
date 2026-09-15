"""Native 2x/8x contact crops, without image resampling or visibility edits."""
import gzip
import hashlib
import json
import os
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw, ImageFont

REV = Path('E:/IcarusWorldAudit/2026-09-06/tactical-visibility-revision')
before = REV/'component7-contact-v18-recovered'
after = REV/'component7-contact-v20'
output = Path(os.environ.get('ICARUS_REVIEW_SHEET_OUTPUT', str(REV/'component7-v18-v20-review-sheets')))
output.mkdir(exist_ok=True)
manifests = [json.loads((p/'manifest.json').read_text()) for p in (before, after)]
rows = manifests[1]['cases']
if os.environ.get('ICARUS_REVIEW_LIMIT'): rows=rows[:int(os.environ['ICARUS_REVIEW_LIMIT'])]
old = {(r['id'], r['side']): r for r in manifests[0]['cases']}
fixtures = {r['id']: r for r in json.loads((REV/'gallery-component7-v20-fixtures/split-fixtures.json').read_text())['cases']}
warp = json.loads(gzip.decompress(Path(manifests[1]['displayWarpFile']).read_bytes()))
font = ImageFont.truetype('C:/Windows/Fonts/segoeui.ttf', 13)
small = ImageFont.truetype('C:/Windows/Fonts/segoeui.ttf', 11)
records = []
for page in range((len(rows)+23)//24):
    image = Image.new('RGB', (1280, 1440), '#18181b')
    draw = ImageDraw.Draw(image)
    draw.text((12, 8), f'Component7 V18 / V20 diagnostic, page {page+1}. Original 8x and 2x pixels.', font=font, fill='white')
    draw.text((12, 29), 'Relative source-ground eye heights. Elevated poses do not assert reachability or constant absolute Z.', font=small, fill='#efc485')
    for slot, row in enumerate(rows[page*24:(page+1)*24]):
        previous = old[(row['id'], row['side'])]
        assert previous['query'] == row['query']
        assert previous['svgSha256'] == row['svgSha256']
        fixture = fixtures[row['id']]
        center = np.array(fixture['sourceDirectedTargetSvg'])
        if row['side'] == 'defense':
            center = np.array(warp['attackToDefenseSvg']['origin'])-center
        x, y = 8+(slot % 4)*320, 60+(slot//4)*226
        draw.text((x,y), f"{row['side']} / {row['id']}", font=small, fill='white')
        sources = []
        for version, folder in enumerate((before, after)):
            draw.text((x+version*152,y+17), f'V{18 if version==0 else 20} / 8x',font=small,fill='#d0d0d0')
            for scale in (8,2):
                source = folder/f"{row['side']}-{row['id']}-{scale}x-overlay.png"
                box = tuple(np.r_[np.floor((center-8)*scale),np.ceil((center+8)*scale)].astype(int))
                crop = Image.open(source).convert('RGB').crop(box)
                location = (x+version*152, y+33 if scale==8 else y+181)
                image.paste(crop,location)
                if scale==2:
                    draw.text((location[0]+38,location[1]+6),'2x',font=small,fill='#d0d0d0')
                sources.append(dict(path=str(source),sha256=hashlib.sha256(source.read_bytes()).hexdigest(),cropPixels=list(map(int,box)),scale=scale))
        records.append(dict(page=page+1,id=row['id'],side=row['side'],query=row['query'],relativeEye=fixture['controlRelativeEyeMeters'],sources=sources))
    path=output/f'page-{page+1:02}.png'
    image.save(path)
(output/'manifest.json').write_text(json.dumps(dict(scope=__doc__,records=records),indent=2))
print('Wrote', (len(rows)+23)//24, 'review sheets for',len(rows),'side cases')

"""Compare candidate contact crops at native pixel sizes, without cone edits."""
import hashlib
import json
import os
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw, ImageFont

R = Path('E:/IcarusWorldAudit/2026-09-06/tactical-visibility-revision')
folders = [Path(os.environ.get('ICARUS_CROP_BEFORE', str(R/'ascent-component5-contact-control'))), Path(os.environ.get('ICARUS_CROP_AFTER', str(R/'ascent-component5-contact-v5')))]
title = os.environ.get('ICARUS_CROP_TITLE', 'Ascent component5')
after_label = os.environ.get('ICARUS_CROP_AFTER_LABEL', 'V5')
before_label = os.environ.get('ICARUS_CROP_BEFORE_LABEL', 'Original control')
out = Path(os.environ.get('ICARUS_ASCENT_EVIDENCE_OUTPUT', str(R/'ascent-component5-control-v5-evidence')))
out.mkdir(exist_ok=True)
sheetdir = out/'sheets'
sheetdir.mkdir(exist_ok=True)
manifests = [json.loads((p/'manifest.json').read_text()) for p in folders]
indices = [{(r['side'], r['id']):r for r in m['cases']} for m in manifests]
fixture_file = Path(os.environ.get('ICARUS_CROP_FIXTURES', str(R/'ascent-connected-component5-candidate-v5/render-fixtures/ascent-fixtures.json')))
fixtures = {r['id']:r for r in json.loads(fixture_file.read_text())['cases']}
font = ImageFont.truetype('C:/Windows/Fonts/segoeui.ttf', 13)
small = ImageFont.truetype('C:/Windows/Fonts/segoeui.ttf', 11)
records = []
sheet = None
selected = list(indices[1].items())
if os.environ.get('ICARUS_ASCENT_EVIDENCE_LIMIT'):
    selected = selected[:int(os.environ['ICARUS_ASCENT_EVIDENCE_LIMIT'])]
for index, (key, current) in enumerate(selected):
    side, case_id = key
    old = indices[0][key]
    assert current['query'] == old['query']
    assert current['svgSha256'] == old['svgSha256']
    fixture = fixtures[case_id]
    region_indices = [{(r['kind'], r['scale'], r['name']):r for r in row['rasterRegions']} for row in (old,current)]
    if index % 16 == 0:
        sheet = Image.new('RGB', (1456, 1210), '#18181b')
        sd = ImageDraw.Draw(sheet)
        sd.text((12,8), f'{title} {before_label} / {after_label}. Original8x and2x pixels. Page{index//16+1}', font=font, fill='white')
        sd.text((12,29), 'Provisional source-ground-relative eye. Opening controls may meet later unrelated blockers. No gameplay certification.', font=small, fill='#efc485')
    slot = index % 16
    sx, sy = 8+(slot%4)*364, 60+(slot//4)*286
    sd.text((sx,sy), f'{side} / {case_id}', font=small, fill='white')
    sd.text((sx,sy+16), f"Eye{fixture['relativeControlEyeMeters']:g}m relative; span{fixture['authoredSpan']}", font=small, fill='#efc485')
    for kind in ('focus','context'):
        source_images = []
        regions = []
        for ri in region_indices:
            reg = ri[('overlay',8.0,kind)]
            regions.append(reg)
            source_images.append(Image.open(reg['path']).convert('RGB'))
        assert regions[0]['pixelRect'] == regions[1]['pixelRect']
        w,h = source_images[0].size
        panel = max(w,340)
        combined = Image.new('RGB', (2*panel+36,h+110), '#18181b')
        draw = ImageDraw.Draw(combined)
        draw.text((12,7), f'{title} / {side} / {case_id} / {kind} / native8x',font=font,fill='white')
        for vi,image in enumerate(source_images):
            draw.text((12+vi*(panel+12),28), before_label if vi==0 else f'{after_label} connected candidate',font=small,fill='white')
            combined.paste(image,(12+vi*(panel+12),48))
        draw.text((12,h+62),f"Control-relative eye{fixture['relativeControlEyeMeters']:g}m. Same physical pose on both sides; original raster pixels.",font=small,fill='#efc485')
        draw.text((12,h+81),fixture.get('expectedAtAuthoredContact','Bounded structural contact diagnostic; source-height gaps retained.'),font=small,fill='#d0d0d0')
        output=out/f'{side}-{case_id}-{kind}-native8x.png'
        combined.save(output)
        records.append(dict(id=case_id,side=side,kind=kind,image=str(output),sha256=hashlib.sha256(output.read_bytes()).hexdigest(),query=current['query'],relativeControlEyeMeters=fixture['relativeControlEyeMeters'],authoredSpan=fixture['authoredSpan'],expectedAtAuthoredContact=fixture.get('expectedAtAuthoredContact'),pixelRect=regions[0]['pixelRect'],changedPixels=int(np.any(np.asarray(source_images[0])!=np.asarray(source_images[1]),axis=2).sum()),sources=[dict(path=r['path'],sha256=hashlib.sha256(Path(r['path']).read_bytes()).hexdigest()) for r in regions]))
        if kind=='focus':
            for vi,image in enumerate(source_images):
                sd.text((sx+vi*180,sy+34),before_label if vi==0 else after_label,font=small,fill='white')
                sheet.paste(image,(sx+vi*180,sy+51))
                image2=Image.open(region_indices[vi][('overlay',2.0,'focus')]['path']).convert('RGB')
                sheet.paste(image2,(sx+vi*180,sy+224))
                sd.text((sx+vi*180+47,sy+232),'2x',font=small,fill='#d0d0d0')
    if slot==15 or index==len(selected)-1:
        sheet.save(sheetdir/f'page-{index//16+1:02}.png')
(out/'manifest.json').write_text(json.dumps(dict(scope=__doc__,complete=all(m.get('complete') for m in manifests),sourceManifests=[dict(path=str(p/'manifest.json'),sha256=hashlib.sha256((p/'manifest.json').read_bytes()).hexdigest()) for p in folders],records=records),indent=2))
print(f'Composed {len(records)} individual views and {(len(selected)+15)//16} sheets')

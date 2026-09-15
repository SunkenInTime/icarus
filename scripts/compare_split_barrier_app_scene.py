"""Exact V26/V29 app-scene pixel and query comparison; no resampling."""
import hashlib
import json
from pathlib import Path

import numpy as np
from PIL import Image, ImageChops, ImageDraw, ImageFont

R = Path('E:/IcarusWorldAudit/2026-09-06/tactical-visibility-revision')
full = [R/'frozen-split-app-scene-v26-run1', R/'frozen-split-app-scene-v29-run1']
individual = [R/'frozen-split-app-individuals-v26-viper-control', R/'frozen-split-app-individuals-v29-run1']
out = R/'split-barrier-v26-v29-app-evidence'
out.mkdir(exist_ok=True)
config = json.loads((full[1]/'aligned-comparisons/manifest.json').read_bytes())
font = ImageFont.truetype('C:/Windows/Fonts/segoeui.ttf', 15)
small = ImageFont.truetype('C:/Windows/Fonts/segoeui.ttf', 12)
manifests = [json.loads((p/'manifest.json').read_bytes()) for p in full]
isolated = [json.loads((p/'manifest.json').read_bytes()) for p in individual]
assert manifests[0]['fixtureSha256'] == manifests[1]['fixtureSha256']
assert manifests[0]['frozenFrame'] == manifests[1]['frozenFrame']
assert manifests[0]['displayWarpSha256'] == manifests[1]['displayWarpSha256']
records = []
for side in ['attack', 'defense']:
    whole = [next(row for row in m['records'] if row['side'] == side and 'native8x' in row['image']) for m in manifests]
    assert whole[0]['sourceQueries'] == whole[1]['sourceQueries']
    single = [next(row for row in m['records'] if row['side'] == side) for m in isolated]
    assert single[0]['sourceQueries'] == single[1]['sourceQueries'] == [whole[0]['sourceQueries'][7]]
    assert single[0]['sourceMeshSha256'] == [whole[0]['sourceMeshSha256'][7]]
    assert single[1]['sourceMeshSha256'] == [whole[1]['sourceMeshSha256'][7]]
    rect = next(row['pixelRect'] for row in config['records'] if Path(row['image']).name.startswith(side + '-iso-viper'))
    full_images = [Image.open(row['image']).convert('RGB') for row in whole]
    delta = np.any(np.asarray(full_images[0]) != np.asarray(full_images[1]), axis=2)
    all_changes = int(delta.sum())
    delta[rect[1]:rect[3], rect[0]:rect[2]] = False
    outside_changes = int(delta.sum())
    assert outside_changes == 0, (side, outside_changes)
    cropped = [Image.open(row['image']).convert('RGB').crop(rect) for row in single]
    width, height = cropped[0].size
    combined = Image.new('RGB', (width*2+36, height+92), '#18181b')
    draw = ImageDraw.Draw(combined)
    for index, (label, image) in enumerate(zip(['V26', 'V29'], cropped)):
        x = 12 + index*(width+12)
        draw.text((x, 10), f'{label} / isolated Viper / {side} / original8x pixels', font=font, fill='white')
        combined.paste(image, (x, 40))
    draw.text((12, height+54), 'Same saved marker, physical source eye and direction. Provisional floor policy; remaining diagonal cutoff is not fixed here.', font=small, fill='#efc485')
    image_path = out/f'{side}-isolated-viper-native8x.png'
    combined.save(image_path)
    records.append(dict(side=side, fullSceneChangedPixels=all_changes,
                        changedPixelsOutsideIsoViperRegion=outside_changes,
                        changedAgentMeshes=[index for index, (a,b) in enumerate(zip(whole[0]['sourceMeshSha256'], whole[1]['sourceMeshSha256'])) if a != b],
                        sourceQueriesIdentical=True, isolatedQueryAndMeshMatchCombined=True,
                        pixelRect=rect, isolatedViperQuery=single[0]['sourceQueries'][0],
                        image=str(image_path), sha256=hashlib.sha256(image_path.read_bytes()).hexdigest(),
                        isolatedCropChangedPixels=int(np.any(np.asarray(cropped[0]) != np.asarray(cropped[1]), axis=2).sum())))
report = dict(scope=__doc__, fixtureSha256=manifests[0]['fixtureSha256'],
              sourceManifests=[dict(path=str(p/'manifest.json'), sha256=hashlib.sha256((p/'manifest.json').read_bytes()).hexdigest()) for p in full+individual],
              records=records, limitation='Original app classes and native output; provisional relative-ground policy. Pixel agreement does not certify live-game visibility.')
(out/'manifest.json').write_text(json.dumps(report, indent=2)+'\n')
print(json.dumps(records))

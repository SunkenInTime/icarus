"""Compare actual white visibility pixels with the authored generator cubic and ink."""
import hashlib,json,gzip,xml.etree.ElementTree as ET
from pathlib import Path
import numpy as np
from PIL import Image,ImageDraw,ImageFont
from svgpathtools import CubicBezier,parse_path
R=Path('E:/IcarusWorldAudit/2026-09-06/tactical-visibility-revision');OUT=R/'generator-v30-curve-raster-review-v3';OUT.mkdir(exist_ok=False)
curve=CubicBezier(40.3722+186.527j,40.3722+186.952j,65.1816+186.704j,77.5863+186.527j)
def curve_y(x):
 lo=0.;hi=1.
 for _ in range(60):
  mid=(lo+hi)*.5
  if curve.point(mid).real<x:lo=mid
  else:hi=mid
 return curve.point((lo+hi)*.5).imag
font=ImageFont.truetype('C:/Windows/Fonts/segoeui.ttf',13);records=[]
for version,folder in [('V29',R/'pipe-generator-contact-v29-control-v1'),('V30',R/'pipe-generator-contact-v30-candidate-v1')]:
 manifest=json.loads((folder/'manifest.json').read_text());warp=json.loads(gzip.decompress(Path(manifest['displayWarpFile']).read_bytes()));reflection=np.array(warp['attackToDefenseSvg']['origin'])
 for side in ['attack','defense']:
  svgpath=Path('assets/maps/split_map'+('_defense' if side=='defense' else '')+'.svg');choices=[]
  for element in ET.parse(svgpath).iter():
   if not element.tag.endswith('path') or element.get('fill','').lower()!='#271406':continue
   for segment in parse_path(element.get('d','')):
    if not isinstance(segment,CubicBezier):continue
    expected=complex(40.3722,186.527) if side=='attack' else complex(425.804,286.473)
    if abs(segment.start-expected)<1e-7:choices.append(segment)
  assert len(choices)==1
  curve=choices[0]
  if side=='defense':curve=CubicBezier(*[complex(reflection[0]-z.real,reflection[1]-z.imag) for z in [curve.start,curve.control1,curve.control2,curve.end]])
  row=next(q for q in manifest['cases'] if q['id']=='generator-generator-curved-front' and q['side']==side)
  for scale in [2,8]:
   regs={q['kind']:q for q in row['rasterRegions'] if q['scale']==scale and q['name']=='focus'};rect=regs['visibility']['pixelRect'];vis=np.array(Image.open(regs['visibility']['path']).convert('RGBA'))[:,:,3];ink=np.array(Image.open(folder/f'{side}-{scale}x-ink.png').convert('RGBA'))[rect[1]:rect[3],rect[0]:rect[2],3]
   xx=(np.arange(rect[0],rect[2])+.5)/scale;yy=(np.arange(rect[1],rect[3])+.5)/scale
   if side=='defense':xx=reflection[0]-xx;yy=reflection[1]-yy
   columns=[];outside=[]
   for col,x in enumerate(xx):
    if not 54<=x<=64:continue
    y=curve_y(x);signed=yy-y
    # Admit only columns demonstrably inside the cone one SVG unit toward its observer.
    interior=np.argmin(abs(signed-1.))
    if vis[interior,col]<128:continue
    window=abs(signed)<1.2
    lit=np.flatnonzero(window&(vis[:,col]>=1));half=np.flatnonzero(window&(vis[:,col]>=128));solidink=np.flatnonzero(window&(ink[:,col]>=128))
    if not len(lit) or not len(half) or not len(solidink):continue
    first=min(lit,key=lambda k:signed[k]);firsthalf=min(half,key=lambda k:signed[k]);wallend=max(solidink,key=lambda k:signed[k]);gap=max(0,round((signed[first]-signed[wallend])*scale)-1)
    between=np.flatnonzero((signed>signed[wallend])&(signed<signed[firsthalf]));deficit=float(np.maximum(0,1-(vis[between,col].astype(float)+ink[between,col])/255).sum())
    columns.append(dict(attackEquivalentX=float(x),authoredCurveY=y,firstCoverageSignedSvg=float(signed[first]),halfCoverageSignedSvg=float(signed[firsthalf]),firstAlpha=int(vis[first,col]),halfAlpha=int(vis[firsthalf,col]),fullyBlankPixelsBeyondInk=gap,coverageDeficitPixels=deficit,litInkOverlapPixels=int(np.sum(window&(vis[:,col]>0)&(ink[:,col]>0)))))
    for rr in np.flatnonzero(window&(signed<0)&(vis[:,col]>0)):
     outside.append(dict(attackEquivalentX=float(x),signedSvg=float(signed[rr]),alpha=int(vis[rr,col]),inkAlpha=int(ink[rr,col])))
   rec=dict(version=version,side=side,scale=scale,columns=columns,outsideCurvePositivePixels=outside,maximumOutsideCurveDistanceSvg=max([-q['signedSvg'] for q in outside],default=0),outsideFartherThanHalfPixel=sum(q['signedSvg']<-.5/scale for q in outside),maximumBlankPixels=max([q['fullyBlankPixelsBeyondInk'] for q in columns],default=None),maximumCoverageDeficitPixels=max([q['coverageDeficitPixels'] for q in columns],default=None),halfCoverageSignedSvgRange=[min(q['halfCoverageSignedSvg'] for q in columns),max(q['halfCoverageSignedSvg'] for q in columns)] if columns else None,pixelRect=rect,sourceImages={k:q['path'] for k,q in regs.items()})
   rec['exactSideCubicInAttackEquivalentCoordinates']=[[z.real,z.imag] for z in [curve.start,curve.control1,curve.control2,curve.end]];rec['maximumAlphaOutsideCurve']=max([q['alpha'] for q in outside],default=0)
   records.append(rec)
   if scale==8:
    images=[Image.open(regs['overlay']['path']).convert('RGB'),Image.fromarray(vis).convert('RGB'),Image.fromarray(ink).convert('RGB')];width=max(210,images[0].width);h=images[0].height;panel=Image.new('RGB',(width*3+48,h+95),'#17171b');draw=ImageDraw.Draw(panel)
    for i,(image,label) in enumerate(zip(images,['Actual palette','White visibility alpha','Actual gold ink alpha'])):draw.text((12+i*(width+12),8),f'{version} {side} / {label}',font=font,fill='white');panel.paste(image,(12+i*(width+12),36))
    draw.text((12,h+48),'Original8x pixels. Cone/ink overlap is measured; no pixels enlarged or modified.',font=font,fill='#e9c28c');panel.save(OUT/f'{version.lower()}-{side}-native8x-masks.png')
report=dict(scope=__doc__,authoredCubicControlPoints=[[z.real,z.imag] for z in [curve.start,curve.control1,curve.control2,curve.end]],curveBoundary='Source authored dark-fill cubic, not its filled gold outline outer edge.',pixelPolicy='Actual raster alpha and exact cubic at pixel centers; up to half-pixel boundary overlap is reported, not silently classified as geometry leakage.',records=records,limitations=['Columns near FOV edges are excluded using visible receiver-side interior.','These are raster contact checks, not proof of native fan geometry or live standing policy.','Opacity in a pixel whose center is outside a curved boundary may be ordinary pixel-area antialiasing; distances and alpha are reported.'],inputs=[dict(path=str(p),sha256=hashlib.sha256(p.read_bytes()).hexdigest()) for p in [Path('assets/maps/split_map.svg'),Path('assets/maps/split_map_defense.svg'),Path(__file__)]])
(OUT/'report.json').write_text(json.dumps(report,indent=2));print(json.dumps([{k:r[k] for k in ['version','side','scale','maximumOutsideCurveDistanceSvg','outsideFartherThanHalfPixel','maximumBlankPixels','maximumCoverageDeficitPixels','halfCoverageSignedSvgRange']} for r in records],indent=2))

"""Freeze screenshot poses and independently measured ramp levels for regression."""
import json,sys
from pathlib import Path
import numpy as np
import shapely
root=Path('E:/IcarusWorldAudit/2026-09-06')
out=dict(version=1,review='scripts/data/reported-sightlines-2026-09-12.json',maps={})
for name in ['abyss','haven']:
 a=json.loads((root/f'tactical-alignment-sides-v1/{name}.json').read_bytes());ma,md=[np.array(a[f'nativeTo{s}Svg']) for s in ['Attack','Defense']]
 def pair(p):
  native=np.linalg.solve(ma[:,:2],np.array(p)-ma[:,2]);return dict(attack=p,defense=(md[:,:2]@native+md[:,2]).tolist())
 rows=([('mid',[206.875,196.25],8,[([239,160],False),([239,175],False),([235,188],False)]),('ramp',[81.875,345],4,[([100,345],False),([70,345],False)]),('ledge',[38.125,321.25],8,[([38.125,300],True)]),('landing',[88,320],6,[([105,320],True),([100,330],False)]),('ledge-edge',[37.88374056,308.30762434],8,[])] if name=='abyss' else [('tower',[357.5,128.125],9,[([330,128.125],False),([350,133],True),([370,170],False),([363,160],False)]),('tower-window',[368,145],9,[([368,170],True),([360,160],False)]),('window-inside',[193.33,320.61],3,[([193.33,300],True)]),('window-sill',[194.15343009,308.51867448],4,[])])
 poses=[dict(id=i,positions=pair(p),expectedFloor=h,rays=[dict(targets=pair(t),visible=v) for t,v in rays]) for i,p,h,rays in rows]
 paths=[]
 if name=='abyss':
  source=json.loads(Path('work/reported-sightlines-final-v2/abyss/source/regional-floors.json').read_bytes());domains=[(s,shapely.from_geojson(json.dumps(s['nativeGeometry']))) for s in source['domains']]
  for y in np.arange(320,346,1):
   p=[82.,float(y)];native=np.linalg.solve(ma[:,:2],np.array(p)-ma[:,2]);cover=[float(np.array(s['nativePlane'])@np.r_[native,1]) for s,shape in domains if shape.covers(shapely.Point(native))];assert cover,(p,'no source floor');paths.append(dict(positions=pair(p),expectedFloor=max(cover)))
 out['maps'][name]=dict(poses=poses,rampPath=paths)
 if name=='haven':out['maps'][name]['towerLowerRays']=[dict(targets=pair(t),visible=v) for t,v in [([350,133],False),([363,160],True)]]
 if name=='haven':out['maps'][name]['reverseWindow']=dict(positions=pair([198.18,256.97]),targets=pair([193.33,320.61]))
Path('test/fixtures/reported_sightlines_2026_09_12.json').write_text(json.dumps(out,indent=2)+'\n')

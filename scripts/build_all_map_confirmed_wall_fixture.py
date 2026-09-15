"""Build both-side wall expectations from reviewed attack-space cases."""
import json,hashlib
from pathlib import Path
import numpy as np
ROOT=Path(r'E:/IcarusWorldAudit/2026-09-06');OUT=Path('test/fixtures/all_map_confirmed_walls_2026_09_14.json')
CASES=[
 ('abyss','atrium-measured-header-block',[48.17988965517242,305.1742805064673],[48.1798896551724,309.94],12.75,True,None),
 ('abyss','atrium-reviewed-upper-opening',[48.17988965517242,305.1742805064673],[48.1798896551724,309.94],9.75,False,None),
 ('ascent','lion-supported-facade-block',[128.9,93.1],[132.45619627797868,92.58371149184447],7.189,True,5.439),
 ('haven','basalt-before-wall-clear',[223.12970503334455,50.451358924171814],[222.3,50.50],4.75,False,3.0),
 ('pearl','mid-wall-before-wall-clear',[260.29555142993854,285.34985],[259.7,285.34985],9.75,False,8.0),
 ('pearl','mid-door-flat-edge-clear',[239.441902,265.418986],[237.440141,263.836330],9.75,False,8.0)]
# Sample complete confirmed conflicts at separated stations to exercise movement.
for name,parent,stations in [('abyss','p7-stroke-0',[2,11,26]),('ascent','p1-fill-3',[145]),('haven','p3-stroke-13',[12]),('pearl','p19-stroke-0',[6,28,57])]:
 inv=json.load(open(f'work/all-map-vision-followup-2026-09-14/wall-inventory/{name}-rays.json'));fam=next(f for f in inv['families'] if f['parent']==parent and f.get('rays'))
 for station in stations:
  rows=[r for r in fam['rays'] if r['station']==station]
  take=rows if name in ('ascent','haven') else rows[:1]
  for j,r in enumerate(take):CASES.append((name,f'{parent}-station-{station}-{j}',r['startSvg'],r['targetSvg'],r['eyeMeters'],True,r['floorMeters']))
out=[]
for name,i,a,b,z,blocked,floor in CASES:
 al=json.load(open(ROOT/f'tactical-alignment-sides-v1/{name}.json'));A=np.array(al['nativeToAttackSvg']);D=np.array(al['nativeToDefenseSvg']);L=D[:,:2]@np.linalg.inv(A[:,:2]);off=D[:,2]-L@A[:,2]
 pair=lambda p:(L@np.array(p)+off).tolist()
 gameplay_floor = floor if name!='ascent' or i=='lion-supported-facade-block' else None
 out.append({'map':name,'id':i,'absoluteEyeMeters':z,'expectedFloorMeters':gameplay_floor,
  'sourceControlFloorMeters': floor if name=='ascent' else None,
  'verifyAutomaticFloor': gameplay_floor is not None,'expectedBlocked':blocked,
  'sides':{'attack':{'origin':a,'target':b},'defense':{'origin':pair(a),'target':pair(b)}}})
review=Path('scripts/data/all-map-confirmed-wall-review-2026-09-14.json');al=json.load(open(ROOT/'tactical-alignment-sides-v1/pearl.json'));A=np.array(al['nativeToAttackSvg']);D=np.array(al['nativeToDefenseSvg']);L=D[:,:2]@np.linalg.inv(A[:,:2]);off=D[:,2]-L@A[:,2]
a=np.array([239.00071119,264.415219])
payload={'reviewSha256':hashlib.sha256(review.read_bytes()).hexdigest(),'cases':out,'floorControls':[{'map':'pearl','id':'opened-mid-door-retains-physical-floor','expectedFloorMeters':8.,'sides':{'attack':a.tolist(),'defense':(L@a+off).tolist()}}]};OUT.write_text(json.dumps(payload,indent=2)+'\n')
print(OUT)





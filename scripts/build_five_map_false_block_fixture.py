"""Build moving, both-side expectations for reviewed false-block openings."""
import gzip,hashlib,json,sys
from pathlib import Path
import numpy as np
from shapely.geometry import LineString,Point
sys.path.insert(0,'scripts')
from compile_reviewed_svg_height_map import polygon

ROOT=Path(r'E:/IcarusWorldAudit/2026-09-06')
DEC=Path('work/all-map-vision-followup-2026-09-14/wall-reviews/assigned-five-map-false-block-adjudication.json')
SRC=Path('work/all-map-vision-followup-2026-09-14/wall-reviews/false-block-families.json')
REVIEW=Path('scripts/data/five-map-false-block-gap-review-2026-09-14.json')
OUT=Path('test/fixtures/five_map_false_block_gaps_2026_09_14.json')
d=json.loads(DEC.read_text());raw=json.loads(SRC.read_text());review=json.loads(REVIEW.read_text());cases=[]
for decision in d['families']:
 if decision['decision']!='fix-required':continue
 fam=next(x for x in raw['families'] if x['map']==decision['map'] and x['parent']==decision['parent'] and x['sourceObject']==decision['sourceObject'])
 rays=fam['positiveRayCandidates'];indexes=sorted({0,len(rays)//2,len(rays)-1})
 alignment=json.load(open(ROOT/f'tactical-alignment-sides-v1/{decision["map"]}.json'));A=np.array(alignment['nativeToAttackSvg']);D=np.array(alignment['nativeToDefenseSvg']);L=D[:,:2]@np.linalg.inv(A[:,:2]);off=D[:,2]-L@A[:,2]
 pair=lambda p:(L@np.asarray(p)+off).tolist()
 operation=f"{decision['map']}-{decision['parent']}-source-{decision['sourceObject']}"
 app=json.load(open('work/all-map-vision-followup-2026-09-14/five-map-gap-candidate-v25/application.json'))
 changed_rows=[x['sourceWallId'] for m in app['maps'] if m['map']==decision['map'] for s in m['sides'] if s['side']=='attack' for x in s['changes'] if x['operation']==operation and x['beforeBands']!=x['afterBands']]
 blocking={w for ray in rays for w in ray['blockingWallIds']}
 changed={wid for wid in blocking if any(source==wid or source.startswith(wid+'-') for source in changed_rows)}
 model=json.load(gzip.open(f'work/all-map-vision-followup-2026-09-14/five-map-gap-compose-input/{decision["map"]}/candidate-attack.json.gz','rt'));walls={w['id']:w for w in model['walls']}
 selected=[]
 for ray in rays:
  a=np.array(ray['startSvg'],float);b=np.array(ray['targetSvg'],float);length=np.linalg.norm(b-a);line=LineString([a,b]);hits=[]
  for wid,w in walls.items():
   local_eye=ray['eyeMeters']-w.get('floorElevationMeters',0.)
   if w.get('unknownHeight') or not any(lo<=local_eye<=hi for lo,hi in w['bands']):continue
   g=line.intersection(polygon(w))
   for p in ([g] if g.geom_type in ('Point','LineString','LinearRing') else list(getattr(g,'geoms',[]))):
    coords=list(p.coords) if hasattr(p,'coords') else []
    for xy in coords:hits.append((np.linalg.norm(np.array(xy)-a),wid))
  local=sorted(x for x in hits if x[1] in changed)
  if not local:continue
  distance,wid=local[0];direction=(b-a)/length
  origin=a.tolist();target=(a+direction*min(length,distance+.08)).tolist();selected.append((ray,origin,target))
 samples=(selected[len(selected)//2:len(selected)//2+1] if decision['map']=='breeze' and decision['sourceObject']==5725 else (selected[:1]+selected[len(selected)//2:len(selected)//2+1]+selected[-1:])[:3])
 for n,(ray,origin,target) in enumerate(samples):
  cases.append({'map':decision['map'],'family':f"{decision['parent']}/source{decision['sourceObject']}",'id':f"{decision['map']}-{decision['sourceObject']}-moving-{n}",'floorMeters':ray['floorMeters'],'eyeMeters':ray['eyeMeters'],'expectedBlocked':False,'standingDomain':ray['sourceDomain'],'sides':{'attack':{'origin':origin,'target':target},'defense':{'origin':pair(origin),'target':pair(target)}}})
 assert selected,(decision['map'],decision['sourceObject'],'no near-source ray starts with the corrected family')
 if (decision['map'],decision['sourceObject']) in {('bind',6721),('bind',829)}:continue
 op=next(o for o in review['operations'] if o['map']==decision['map'] and o['sourceObject']==decision['sourceObject'])
 if op['mode']=='object-top-clip':negative_eye=sum(decision['primaryZBoundsMeters'])/2
 else:
  solids=[band for station in op['stations'] for band in station['completeLocalSourceBands'] if band[1]-band[0]>.05]
  band=max(solids,key=lambda x:x[1]-x[0]);negative_eye=sum(band)/2
 if (decision['map'],decision['sourceObject'])==('corrode',4801):negative_eye=16.0
 ray,origin,target=samples[0]
 cases.append({'map':decision['map'],'family':f"{decision['parent']}/source{decision['sourceObject']}",'id':f"{decision['map']}-{decision['sourceObject']}-solid-control",'floorMeters':None,'eyeMeters':negative_eye,'expectedBlocked':True,'standingDomain':None,'sides':{'attack':{'origin':origin,'target':target},'defense':{'origin':pair(origin),'target':pair(target)}}})
 if (decision['map'],decision['sourceObject'])==('corrode',4801):
  cases.append({'map':'corrode','family':'p2-stroke-5/source4801','id':'corrode-4801-retained-header-15_2m','floorMeters':None,'eyeMeters':15.2,'expectedBlocked':True,'standingDomain':None,'controlRole':'structural-height-control-no-physical-standing-claim','sides':{'attack':{'origin':origin,'target':target},'defense':{'origin':pair(origin),'target':pair(target)}}})
payload={'reviewSha256':hashlib.sha256(REVIEW.read_bytes()).hexdigest(),'decisionSha256':hashlib.sha256(DEC.read_bytes()).hexdigest(),'utilityWidgetFixture':{'selection':'automatic','supportedFloorMeters':11.9994,'automaticEyeMeters':13.7494,'behavior':'receiver-backed moving poses see through the measured aperture; structural 15.2m and 16m controls retain the source facade/header'},'cases':cases};OUT.write_text(json.dumps(payload,indent=2)+'\n');print(OUT,len(cases))









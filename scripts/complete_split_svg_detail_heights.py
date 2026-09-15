"""Complete reviewed Split detail associations; retain assembly envelopes explicitly.

Only height annotations change. Every partition is a subset of existing ink.
Source assembly envelopes are conservative bounds, not exact wall-top profiles.
"""
import argparse, copy, gzip, json, math
from pathlib import Path
import numpy as np
import shapely

ROOT=Path('E:/IcarusWorldAudit/2026-09-06')
REV=ROOT/'tactical-visibility-revision'
# ID, source objects, native floor reference, readable name.
WHOLE=[
 ('p3-unknown-1',[5860,5802],1.,'A Rafters ledge and cover'),
 ('p4-unknown-0',[5919],2.,'A Ramp tower ledge'),
 ('p6-unknown-0',[5859,5896],6.5,'A Tower doorway return'),
 ('p6-unknown-1',[5825],0.,'A Site sign'),
 ('p7-unknown-0',[5928,5932],6.5,'A Tower ramp wall return'),
 ('p9-unknown-1',[1094,1095,6262,6263,6294,1326],3.,'B Lobby barriers'),
 ('p9-unknown-4',[7277,7144,7244,3115],5.,'B Tower pallet and fan cover'),
 ('p9-unknown-6',[7606],4.5,'Mid Market low wall'),
 ('p9-unknown-8',[4134,7490],4.5,'Mid Market refrigerator stack'),
 ('p9-unknown-10',[7612],6.5,'Mid Vents left door jamb'),
 ('p9-unknown-11',[3954,3955,3956,3957],4.5,'Mid double crate stacks'),
 ('p9-unknown-13',[7461,7555,7556,7408],4.5,'Mid barrel and crate cover'),
 ('p10-unknown-0',[7612],6.5,'Mid Vents right door jamb'),
 ('p13-unknown-0',[6782],3.,'B Site street cart'),
 ('p13-unknown-3',[6965],5.,'B Tower window return'),
 ('p15-unknown-0',[7796],2.5,'Vents room walls'),
 ('p16-unknown-0',[6945],3.,'B Site raised balcony'),
 ('p16-unknown-2',[6161],-1.,'A Sewer entrance raised floor edge'),
 ('p17-unknown-0',[6951,6832,6949,6950],3.,'B Tower catwalk and lift'),
]
# Parent ink is cut at the actual shared painted edge. Higher cover owns the stroke.
PARTS=[
 ('p3-unknown-0','Vents fan cover',1,201.662,
  [('north',[7796],2.5,False),('south',[7808,7809,7811],2.5,True)]),
 ('p4-unknown-1','A Lobby wall and planter',1,316.213,
  [('wall',[6183],3.,False),('planter',[906],3.,True)]),
 ('p9-unknown-5','Mid Market counters',1,289.1,
  [('door-return',[7654,7655],3.5,False),('counter',[3946,3947,3948,3943,3944,3945,3952,3953,4140,4142,4143,7557],3.5,True)]),
 ('p14-unknown-0','B Garage crate and tools',0,25.455,
  [('crate',[6560],3.,False),('tools',[6763,6761],3.,True)]),
 ('p14-unknown-1','B Lobby low cover and counter',1,312.491,
  [('counter',[1226,6289,6257],3.,False),('fan-and-box',[1428,6437],3.,True)]),
]
MAIN={
 'p1-unknown-0':[6151,5849,5857,6419,6146,6145,7107,6183,7334,7330,6178],
 'p1-unknown-1':[6577],
 'p1-unknown-2':[7605,6961,7604,6966,6696,6348,6354,7607],
 'p1-unknown-3':[6946,7205,6948,6831,6966,6726,6727],
 'p1-unknown-4':[6178,7896,7700,6168,6354,7897,6165,7604],
 'p1-unknown-5':[5927,7338,6947,6958,6966,7795,7791,6957],
 'p1-unknown-6':[7700,6169,7897,6166,7899,7898,7609,5917],
 'p1-unknown-7':[5857,5927,7106,5852,5853,5860,5859,429],
 'p1-unknown-8':[5918,5928,5859,5860,5927,5932,5896,5919],
 'p1-unknown-9':[5866,5801],
}

def poly(w):
 r=[np.array(q).reshape(-1,2) for q in w['rings']]
 return shapely.Polygon(r[0],r[1:])
def rings(p):return [np.array(q.coords).reshape(-1).tolist() for q in [p.exterior,*p.interiors]]

def main():
 ap=argparse.ArgumentParser(description=__doc__);ap.add_argument('--out',type=Path,required=True);args=ap.parse_args();args.out.mkdir(exist_ok=False)
 base=REV/'split-svg-semantic-prototype-v12';models={s:json.loads((base/f'split-{s}.json').read_text()) for s in ['attack','defense']};old=copy.deepcopy(models)
 gp=ROOT/'supplemented-v2/world/split/geometry.npz';raw=np.load(gp);objects=json.loads(gp.with_suffix('.json').read_text())['objects'];report=[]
 def evidence(ids,floor,label):
  rows=[]
  for oid in ids:
   o=objects[oid];ids0=np.arange(o['firstFace'],o['firstFace']+o['faceCount']);t=raw['points'][raw['faces'][ids0]];top=float(t[:,:,2].max());rows.append(dict(index=oid,path=o['path'],topZ=top,topFaces=ids0[(t[:,:,2]==top).any(1)].tolist()))
  top=max(q['topZ'] for q in rows)
  return dict(label=label,sourceGeometry=str(gp),sourceObjects=rows,floorElevationMeters=floor,maximumSourceZ=top,upperBoundMeters=top-floor,interpretation='Solid represented assembly up to its measured maximum. Cosmetic gaps do not open it. Upper bound is conservative, not a pointwise top profile.')
 def mate(w):
  p=np.concatenate([np.array(q).reshape(-1,2) for q in w['rings']]);p=np.array([466.1762,473])-p;b=np.r_[p.min(0),p.max(0)]
  found=[q for q in old['defense']['walls'] if q['sourcePathIndex']==w['sourcePathIndex'] and max(abs(np.array(poly(q).bounds)-b))<.002];assert len(found)==1,w['id'];return found[0]
 def annotate(w,e):
  q=copy.deepcopy(w);q.update(bands=[[0,e['upperBoundMeters']]],unknownHeight=False,heightModel='source-assembly-upper-bound',heightEvidence=e);return q
 def replace(attack_id,fn):
  a=next(w for w in old['attack']['walls'] if w['id']==attack_id)
  for side,w in [('attack',a),('defense',mate(a))]:
   parts=fn(side,w);union=shapely.union_all([poly(q) for q in parts]);assert poly(w).symmetric_difference(union).area<1e-8
   models[side]['walls']=[q for q in models[side]['walls'] if q['id']!=w['id']]+parts
 for wid,ids,floor,label in WHOLE:
  e=evidence(ids,floor,label)
  replace(wid,lambda s,w:[annotate(w,e)]);report.append(dict(parent=wid,evidence=e))
 for wid,ids in MAIN.items():
  e=evidence(ids,0.,'Structural SVG assembly '+wid);e['interpretation']='Conservative source-assembly envelope. Nearby source sections support structural identity; this does not establish exact tops or every gameplay sightline along the compound.'
  replace(wid,lambda s,w:[annotate(w,e)]);report.append(dict(parent=wid,evidence=e,scope='conservative structural compound; exact per-span heights not certified'))
 for wid,label,axis,cut,roles in PARTS:
  evidences={role:evidence(ids,floor,label+' '+role) for role,ids,floor,_ in roles}
  def partition(side,w):
   result=[];split=cut if side=='attack' else [466.1762,473][axis]-cut
   for role,_,_,greater0 in roles:
    greater=greater0 if side=='attack' else not greater0
    b=[-1000.,-1000.,1000.,1000.];b[axis if greater else axis+2]=split
    for index,p in enumerate(shapely.get_parts(poly(w).intersection(shapely.box(*b)))):
     if not isinstance(p,shapely.Polygon) or p.area<1e-12:continue
     q=annotate(w,evidences[role]);q.update(id=f'{w["id"]}-{role}-{index}',parentWallId=w['id'],rings=rings(p));result.append(q)
   return result
  replace(wid,partition);report.append(dict(parent=wid,axis=axis,attackCut=cut,evidence=evidences))
 # The authored 0.5-unit A Main line depicts the connected floor-height change.
 # Its endpoint joins the unchanged enclosing structural wall.
 e=dict(label='A Main connected floor edge',sourceObjects=[6158,6171,6156],interpretation='Connected terrain, not an added vision wall. Source MainVault contains the low slab; endpoint structures remain on the enclosing SVG component.')
 def terrain(side,w):
  q=copy.deepcopy(w);q.update(bands=[],unknownHeight=False,heightModel='connected-ground-transition',heightEvidence=e);return [q]
 replace('p16-unknown-3',terrain);report.append(dict(parent='p16-unknown-3',evidence=e))
 # B Site pile: upper short crate, tall central scrap stack, side fan under its sheet.
 def pile(side,w):
  boxes=[('short-crate',[-1000,-1000,1000,205.697],[6648],3.),('stack',[-1000,205.697,10.03771,1000],[6567,6649,2024,6621,1676,6556,6669,6751],3.),('side', [10.03771,205.697,1000,1000],[6752,1673,6810,6811],3.)]
  out=[]
  for role,b,ids,floor in boxes:
   b=np.array(b,float)
   if side=='defense':b=np.r_[np.array([466.1762,473])-b[2:],np.array([466.1762,473])-b[:2]]
   for i,p in enumerate(shapely.get_parts(poly(w).intersection(shapely.box(*b)))):
    if not isinstance(p,shapely.Polygon) or p.area<1e-12:continue
    q=annotate(w,evidence(ids,floor,'B Site pile '+role));q.update(id=f'{w["id"]}-{role}-{i}',parentWallId=w['id'],rings=rings(p));out.append(q)
  return out
 replace('p12-unknown-0',pile)
 for side,m in models.items():
  assert not any(w['unknownHeight'] for w in m['walls'])
  assert m['receiver']==old[side]['receiver'] and m['supports']==old[side]['supports']
  m['limitations']=['Structural assembly heights are conservative upper bounds. Exact per-span tops and every live-game sightline are not certified.','Explicit supports are required where the 2D position alone cannot choose between stacked surfaces.']
  (args.out/f'split-{side}.json').write_text(json.dumps(m,separators=(',',':')))
 for p in base.iterdir():
  if p.is_file() and p.name not in ['split-attack.json','split-defense.json']:(args.out/p.name).write_bytes(p.read_bytes())
 (args.out/'completion-evidence.json').write_text(json.dumps(report,indent=2));print(json.dumps({s:len(m['walls']) for s,m in models.items()}))
if __name__=='__main__':main()

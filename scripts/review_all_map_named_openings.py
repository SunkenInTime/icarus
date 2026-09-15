"""Assign reviewed vertical gaps to their existing painted SVG footprints."""
import gzip
import json
import numpy as np
import shapely
from shapely.affinity import affine_transform
from audit_all_map_gameplay_levels import OUT, ROOT, read
from compile_reviewed_svg_height_map import polygon, rings
from review_icebox_gameplay_openings import vertical_intervals


def review(name):
 directory=OUT/name
 models={s:read(directory/(f'height-base-{s}.json.gz' if (directory/f'height-base-{s}.json.gz').exists() else f'before-{s}.json.gz')) for s in ['attack','defense']}
 # Always start the edited parent from the immutable pre-review asset.
 originals={s:read(directory/f'before-{s}.json.gz') for s in models}
 objects=read(ROOT/f'supplemented-v2/world/{name}/geometry.json')['objects']
 alignment=read(ROOT/f'tactical-alignment-sides-v1/{name}.json');a=np.array(alignment['nativeToAttackSvg']);b=np.array(alignment['nativeToDefenseSvg'])
 linear=b[:,:2]@np.linalg.inv(a[:,:2]);offset=b[:,2]-linear@a[:,2];transform=[*linear[0],*linear[1],*offset]
 wid='p11-fill-0' if name=='lotus' else 'p29-stroke-1'
 attack=next(w for w in originals['attack']['walls'] if w['id']==wid);shape=polygon(attack)
 target=affine_transform(shape,transform)
 defense=min(originals['defense']['walls'],key=lambda w:target.hausdorff_distance(polygon(w)))
 assert target.hausdorff_distance(polygon(defense))<.01
 specs=[]
 if name=='lotus':
  base=float(objects[4302]['boundsMeters'][1][2]);plinth=float(objects[4301]['boundsMeters'][1][2])
  ceiling=[float(objects[4292]['boundsMeters'][0][2]),float(objects[4292]['boundsMeters'][1][2])]
  specs=[(shapely.box(244.8,-1000,1000,200),[[0.,plinth],ceiling],[4301,4292]),(None,[[0.,base],ceiling],[4302,4292])]
  reason='B Site stepwell rim is below the surrounding standing eye. The ceiling ring is overhead. Keep the taller northeast plinth separate.'
  references=['https://playvalorant.com/en-us/news/game-updates/valorant-patch-notes-8-0/','https://www.oneesports.gg/valorant/lotus-callouts-locations/']
 else:
  ids=[6943,6944,6945,6950,6949,6957]
  mesh=np.load(ROOT/f'supplemented-v2/world/{name}/geometry.npz')
  tri=np.concatenate([mesh['points'][mesh['faces'][objects[i]['firstFace']:objects[i]['firstFace']+objects[i]['faceCount']]] for i in ids]).astype(float)
  tri[:,:,:2]=tri[:,:,:2]@a[:,:2].T+a[:,2]
  edges=np.linspace(123.51,143.475,41)
  for start,end in zip(edges,edges[1:]):
   measured=vertical_intervals(tri,1,[159.3,160.9],[start,end])
   lower=[hi for lo,hi in measured if lo<8];upper=[lo for lo,hi in measured if lo>=8]
   if not lower or not upper:raise ValueError(('Missing measured doorway bands',start,measured))
   bottom=max(lower);ceiling=min(upper)
   # Fill small construction seams below the sill and above the lintel.
   # The gameplay opening is the single broad gap between them.
   bands=[[0.,max(hi for lo,hi in measured)]] if bottom>=ceiling else [[0.,bottom],[ceiling,max(hi for lo,hi in measured)]]
   specs.append((shapely.box(start,-1000,end,1000),bands,ids))
  specs.append((None,[[0.,max(objects[i]['boundsMeters'][1][2] for i in ids)]],ids))
  reason='B Hall front opening is above the solid tunnel base and below its local ceiling. The first jamb section remains solid. Floor navigation independently corroborates the upper hall.'
  references=['https://playvalorant.com/en-us/news/game-updates/valorant-patch-notes-6-11/']
 evidence=[]
 for side,original in [('attack',attack),('defense',defense)]:
  remaining=polygon(original);parts=[]
  for index,(clip,bands,ids) in enumerate(specs):
   region=remaining if clip is None else remaining.intersection(affine_transform(clip,transform) if side=='defense' else clip)
   for j,p in enumerate(shapely.get_parts(region)):
    if p.geom_type!='Polygon' or p.area<1e-12:continue
    part=dict(original,id=f'{original["id"]}-gameplay-opening-{index}-{j}',rings=rings(p),floorElevationMeters=0.,bands=bands,unknownHeight=False)
    parts.append(part)
   remaining=remaining.difference(region)
   if side=='attack':evidence.append(dict(index=index,clipBounds=None if clip is None else list(clip.bounds),bands=bands,sourceObjects=ids,sourcePaths=[objects[i]['path'] for i in ids]))
  assert remaining.area<1e-7
  assert polygon(original).symmetric_difference(shapely.union_all([polygon(p) for p in parts])).area<1e-7
  model=models[side];model['walls']=[w for w in model['walls'] if w['id']!=original['id'] and not w['id'].startswith(original['id']+'-gameplay-opening-')]+parts
  (directory/f'height-base-{side}.json.gz').write_bytes(gzip.compress(json.dumps(model,separators=(',',':'),allow_nan=False).encode(),mtime=0))
 (directory/'named-opening-review.json').write_text(json.dumps(dict(map=name,wallId=wid,reason=reason,references=references,evidence=evidence),indent=2))
 print(name,wid,len(specs),'sections',flush=True)


if __name__=='__main__':
 for name in ['lotus','pearl']:review(name)

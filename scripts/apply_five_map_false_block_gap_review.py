"""Apply independently measured false-block openings to a composed model root."""
import argparse,copy,gzip,hashlib,json
from pathlib import Path
import numpy as np
import shapely
from shapely.geometry import MultiPoint,Polygon
from compile_reviewed_svg_height_map import polygon
from restore_exposed_standing_floors import restore_exposed_floors

REVIEW=Path('scripts/data/five-map-false-block-gap-review-2026-09-14.json')
ALIGN=Path(r'E:/IcarusWorldAudit/2026-09-06/tactical-alignment-sides-v1')
def sha(p):return hashlib.sha256(Path(p).read_bytes()).hexdigest()
def read(p):
 raw=Path(p).read_bytes();return json.loads(gzip.decompress(raw) if str(p).endswith('.gz') else raw)
def source(root,name,side):
 choices=[root/name/f'candidate-{side}.json.gz',root/f'{name}_svg_height_{side}.json.gz']
 got=[p for p in choices if p.exists()];assert len(got)==1,(name,side,got);return got[0]
def parts(g):return [x for x in shapely.get_parts(shapely.make_valid(g)) if x.geom_type=='Polygon' and x.area>1e-9]
def rings(g):return [[v for xy in list(r.coords) for v in xy] for r in [g.exterior,*g.interiors]]
def subtract(bands,cuts):
 if cuts and isinstance(cuts[0],(int,float)):cuts=[cuts]
 out=[]
 for lo,hi in bands:
  rows=[[float(lo),float(hi)]]
  for a,b in cuts:
   rows=[[x,min(y,a)] for x,y in rows if x<a]+[[max(x,b),y] for x,y in rows if y>b]
  out.extend(x for x in rows if x[1]>x[0]+1e-8)
 return out
def transform_point(p,M):return (M[:,:2]@np.asarray(p)+M[:,2]).tolist()
def build(root,out,review_path=REVIEW):
 review=read(review_path);assert sha(review_path)==sha(REVIEW)
 assert sha(review['decisionInput'])==review['decisionInputSha256'], 'decision input changed'
 for p,h in review['sourceInventories'].items():assert sha(p)==h,('source inventory changed',p)
 for p,h in {**review['directGeometrySources'],**review.get('apertureEvidence',{})}.items():assert sha(p)==h,('source geometry/evidence changed',p)
 for e in review['standingSources'].values():assert sha(e['path'])==e['sha256'],('standing source changed',e['path'])
 for e in review['alignmentSources'].values():assert sha(e['path'])==e['sha256'],('alignment changed',e['path'])
 assert all(o['mode']=='measured-station-gaps' for o in review['operations'])
 assert not out.exists();out.mkdir(parents=True)
 results=[]
 for name in sorted({o['map'] for o in review['operations']}):
  alignment=read(ALIGN/f'{name}.json');A=np.array(alignment['nativeToAttackSvg']);D=np.array(alignment['nativeToDefenseSvg'])
  attack=read(source(root,name,'attack'));folder=out/name;folder.mkdir();side_rows=[]
  for side,M in [('attack',A),('defense',D)]:
   src=source(root,name,side);before=read(src);model=copy.deepcopy(before);changed=[]
   for op in [o for o in review['operations'] if o['map']==name]:
    lo,hi=np.array(op['openingSourceBoundsXYMeters'],dtype=float)
    assert np.all(hi-lo>1e-6),(name,op['id'],'degenerate unreviewed source bounds')
    corners=[lo,[lo[0],hi[1]],hi,[hi[0],lo[1]]]
    clip=Polygon([transform_point(x,M) for x in corners])
    if op['mode']=='measured-station-gaps':
     points=[transform_point(np.linalg.inv(A[:,:2])@(np.array(s['attackSvg'])-A[:,2]),M) for s in op['stations']]
     cells=[clip] if len(points)==1 else list(shapely.get_parts(shapely.voronoi_polygons(MultiPoint(points),extend_to=clip,ordered=True)))
     assignments=[]
     for station,cell in zip(op['stations'],cells):
      spec=station['sides'][side];assignments.extend((wid,cell.intersection(clip),spec['removeIntervalsMeters'],station['station']) for wid in spec['wallIds'] if spec['removeIntervalsMeters'])
    by={}
    for wid,region,cuts,station in assignments:by.setdefault(wid,[]).append((region,cuts,station))
    rewritten=[];matched_sources=set()
    for wall in model['walls']:
     keys=[wid for wid in by if wall['id']==wid]
     if not keys:rewritten.append(wall);continue
     assert len(keys)==1,(name,side,op['id'],wall['id'],keys)
     source_id=keys[0]
     matched_sources.add(source_id)
     assert not wall.get('unknownHeight',False),(name,side,op['id'],wall['id'])
     base=polygon(wall);remaining=base;pieces=[]
     for region,cuts,station in by[source_id]:
      hit=remaining.intersection(region)
      for n,g in enumerate(parts(hit)):
       local_cuts=[[a-wall.get('floorElevationMeters',0.),b-wall.get('floorElevationMeters',0.)] for a,b in ([cuts] if cuts and isinstance(cuts[0],(int,float)) else cuts)]
       w=copy.deepcopy(wall);w['id']=f"{wall['id']}-{op['id']}-{station}-{n}";w['rings']=rings(g);w['bands']=subtract(wall['bands'],local_cuts);pieces.append(w)
       changed.append({'operation':op['id'],'sourceWallId':wall['id'],'wallId':w['id'],'station':station,'beforeBands':wall['bands'],'afterBands':w['bands']})
      remaining=remaining.difference(region)
     for n,g in enumerate(parts(remaining)):
      w=copy.deepcopy(wall);w['id']=f"{wall['id']}-{op['id']}-remainder-{n}";w['rings']=rings(g);pieces.append(w)
     assert pieces,(name,side,op['id'],wall['id'])
     assert shapely.symmetric_difference(base,shapely.union_all([polygon(w) for w in pieces])).area<1e-8,(name,side,op['id'],wall['id'],'footprint changed')
     assert any(w['bands'] for w in pieces),(name,side,op['id'],wall['id'],'collapsed entire wall')
     rewritten.extend(pieces)
    assert matched_sources==set(by),(name,side,op['id'],'unmatched wall ids',set(by)-matched_sources)
    model['walls']=rewritten
   standing=read(review['standingSources'][name]['path'])
   restored=restore_exposed_floors(name,before,model,standing,M)
   assert all(model[k]==before[k] for k in before if k not in ('walls','supports'))
   model['sourceFalseBlockGapReviewSha256']=sha(review_path)
   dst=folder/f'candidate-{side}.json.gz';dst.write_bytes(gzip.compress(json.dumps(model,separators=(',',':'),allow_nan=False).encode(),mtime=0))
   side_rows.append({'side':side,'inputSha256':sha(src),'outputSha256':sha(dst),'changedPieceCount':len(changed),'changes':changed,'restoredStanding':restored})
  results.append({'map':name,'sides':side_rows})
 app={'reviewSha256':sha(review_path),'algorithmSha256':sha(__file__),'maps':results};(out/'application.json').write_text(json.dumps(app,indent=2)+'\n');return app
if __name__=='__main__':
 p=argparse.ArgumentParser();p.add_argument('--assets-dir',type=Path,required=True);p.add_argument('--output',type=Path,required=True);a=p.parse_args();print(json.dumps(build(a.assets_dir,a.output)))

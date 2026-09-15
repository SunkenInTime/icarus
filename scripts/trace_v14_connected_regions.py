import sys,json,gzip
from pathlib import Path
sys.path.insert(0,'scripts')
import numpy as np
from PIL import Image,ImageDraw,ImageFont
import shapely
from audit_wall_contact_pixels import PhysicalGeometry
from tactical_alignment_composite import IndexedTriangles
from audit_all_map_wall_span_coverage import authored_spans
from native_reference_cast import NativeReferenceModel
R=Path('E:/IcarusWorldAudit/2026-09-06/tactical-visibility-revision')
F=R/'tower-diagonal84-contact-v14'; old=R/'diagonal-contact-split-candidate-v1'; C=R/'split-wall-family-normalized-candidate-v14'
m=json.loads((F/'manifest.json').read_text());w=json.loads(gzip.decompress(Path(m['displayWarpFile']).read_bytes()));r=next(r for r in m['cases'] if r['side']=='attack' and r['id']=='diagonal-84-end-corner')
g=PhysicalGeometry(w,r,np.fromfile(r['prefix']+'-shadow.f32',dtype='<f4'));q=np.array(r['query']); st=IndexedTriangles(g.source,g.indices)
def forward(p):
 p=np.atleast_2d(p);ids=st.find_simplex(p);t=st.transform[ids];u=np.einsum('nij,nj->ni',t[:,:2],p-t[:,2]);return np.einsum('ni,nij->nj',np.c_[u,1-u.sum(1)],g.target[g.indices[ids]])
source_polys=shapely.polygons(g.source[g.indices]); tree=shapely.STRtree(source_polys)
spans=authored_spans(Path('assets/maps/split_map.svg'))
v=np.array(Image.open(F/'attack-diagonal-84-end-corner-8x-visibility.png'))[:,:,3];o=np.array(Image.open(old/'attack-diagonal-84-end-corner-8x-visibility.png'))[:,:,3]
selected=[]
for sy in [184,186,190,194,197]:
 y=int(sy*8); xs=np.flatnonzero((v[y]>=200)&(o[y]<40));xs=xs[(xs>319*8)&(xs<345*8)]
 if len(xs):selected.append([(float(xs[len(xs)//2])+.5)/8,(y+.5)/8])
model=NativeReferenceModel(C/'split.height.bin.gz',R/'native-tactical-rays-build/Release/tactical_reference_cast.dll')
prov=np.load(C/'normalized-face-provenance.npz');cf=np.load(C/'correspondence.npz')['sourceFaces'];full=np.load(R/'global-ground-complete-v2/split/correspondence.npz')['sourceFaces'];orig=np.load(R/'full-height-input-v1/split/source-correspondence.npz')['sourceFaces'];meta=json.loads((R.parent/'supplemented-v2/world/split/geometry.json').read_text());raw=np.load(R.parent/'supplemented-v2/world/split/geometry.npz');starts=np.array([a['firstFace'] for a in meta['objects']])
def info(face):
 control=int(cf[face]);f=int(full[control]);original=int(orig[f]);oi=int(np.searchsorted(starts,original,side='right')-1);tri=raw['points'][raw['faces'][original]]
 return dict(face=int(face),control=control,full=f,original=original,object=oi,path=meta['objects'][oi]['path'],rawTriangle=tri.tolist())

F=R/'tower-contact-v14';old=R/'tower-contact-original-control';m=json.loads((F/'manifest.json').read_text());fixtures=json.loads((R/'gallery-connected-tower-v14/split-fixtures.json').read_text());out=R/'tower-v14-region-traces';out.mkdir(exist_ok=True)
for id in ['short99-frontage','97-short99-join','92-raised-profile']:
 r=next(x for x in m['cases'] if x['id']==id and x['side']=='attack');q=np.array(r['query']);g=PhysicalGeometry(w,r,np.fromfile(r['prefix']+'-shadow.f32',dtype='<f4'))
 fixture=next(x for x in fixtures['cases'] if x['id']==id);target=np.array(fixture['targetSvg']);lower=target-[10,10];upper=target+[10,10]
 v=np.array(Image.open(F/f'attack-{id}-8x-visibility.png'))[:,:,3];o=np.array(Image.open(old/f'attack-{id}-8x-visibility.png'))[:,:,3]
 selected=[]
 for y in range(int(lower[1]*8),int(upper[1]*8),3):
  xs=np.flatnonzero((v[y]>=200)&(o[y]<40));xs=xs[(xs>lower[0]*8)&(xs<upper[0]*8)]
  if len(xs):
   for x in np.unique([xs[0],xs[len(xs)//2],xs[-1]]):selected.append([(float(x)+.5)/8,(y+.5)/8])
 rows=[]
 for svg in selected:
  targetNative=g.native(svg)[0];delta=targetNative-q[:2];line=shapely.LineString([q[:2],targetNative]);ts=[0.,1.]
  for cell in tree.query(line,predicate='intersects'):
   coords=shapely.get_coordinates(shapely.intersection(line,source_polys[cell]));ts.extend(((coords-q[:2])@delta/(delta@delta)).tolist())
  ts=np.unique(np.round(ts,14));mapped=forward(q[:2]+ts[:,None]*delta);crossings=[]
  for i in range(len(ts)-1):
   if np.linalg.norm(mapped[i+1]-mapped[i])<1e-12:continue
   piece=shapely.LineString(mapped[i:i+2])
   for rec,seg in spans:
    if rec['segmentType']!='Line':continue
    inter=shapely.intersection(piece,shapely.LineString([rec['startSvg'],rec['endSvg']]))
    for pt in shapely.get_coordinates(inter):
     frac=float(np.dot(pt-mapped[i],mapped[i+1]-mapped[i])/np.dot(mapped[i+1]-mapped[i],mapped[i+1]-mapped[i])); t=ts[i]+frac*(ts[i+1]-ts[i]);crossings.append(dict(edge=rec['legacyStraightEdgeIndex'],span=rec['span'],svg=pt.tolist(),native=(q[:2]+t*delta).tolist(),t=float(t)))
  hit=model.cast(q[:3],np.r_[targetNative,q[2]]);stop=model.cast(q[:3],np.r_[q[:2]+delta/np.linalg.norm(delta)*q[5],q[2]])
  rows.append(dict(svg=svg,hit=hit,crossings=sorted(crossings,key=lambda x:x['t']),stop=stop,stopSource=info(stop['face']) if stop else None))
 result=dict(id=id,query=q.tolist(),originSvg=forward(q[:2])[0].tolist(),count=len(rows),crossed=sum(bool(x['crossings']) for x in rows),blocked=sum(x['hit'] is not None for x in rows),rows=rows)
 (out/f'{id}.json').write_text(json.dumps(result,indent=2));print(id,result['count'],'crossed',result['crossed'],'blocked',result['blocked'],'edges',sorted(set(c['edge'] for x in rows for c in x['crossings'] if c['edge'] is not None)))

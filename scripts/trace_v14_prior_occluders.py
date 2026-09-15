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


base=NativeReferenceModel(R/'global-ground-complete-v2/split/split.height.bin.gz',R/'native-tactical-rays-build/Release/tactical_reference_cast.dll')
records=[]
for id in ['short99-frontage','97-short99-join','92-raised-profile']:
 data=json.loads((out/f'{id}.json').read_text());q=np.array(data['query']);r=next(x for x in m['cases'] if x['id']==id and x['side']=='attack');g=PhysicalGeometry(w,r,np.fromfile(r['prefix']+'-shadow.f32',dtype='<f4'));samples=[]
 for row in data['rows'][::max(1,len(data['rows'])//10)]:
  xy=g.native(row['svg'])[0];hit=base.cast(q[:3],np.r_[xy,q[2]])
  if hit:
   control=hit['face'];fid=int(full[control]);original=int(orig[fid]);oi=int(np.searchsorted(starts,original,side='right')-1);samples.append(dict(svg=row['svg'],priorHit=hit,full=fid,original=original,object=oi,path=meta['objects'][oi]['path'],rawTriangle=raw['points'][raw['faces'][original]].tolist()))
 records.append(dict(id=id,query=q.tolist(),samples=samples));print(id,sorted(set((x['object'],x['original']) for x in samples)))
(out/'prior-occluders.json').write_text(json.dumps(records,indent=2))

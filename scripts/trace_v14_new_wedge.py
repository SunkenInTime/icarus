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
rows=[]
for svg in selected:
 target=g.native(svg)[0];delta=target-q[:2];line=shapely.LineString([q[:2],target]);ts=[0.,1.]
 for cell in tree.query(line,predicate='intersects'):
  inter=shapely.intersection(line,source_polys[cell]);coords=shapely.get_coordinates(inter)
  ts.extend(((coords-q[:2])@delta/(delta@delta)).tolist())
 ts=np.unique(np.round(ts,14));mapped=forward(q[:2]+ts[:,None]*delta);crossings=[]
 for i in range(len(ts)-1):
  piece=shapely.LineString(mapped[i:i+2])
  for rec,seg in spans:
   if rec['segmentType']!='Line':continue
   inter=shapely.intersection(piece,shapely.LineString([rec['startSvg'],rec['endSvg']]))
   for pt in shapely.get_coordinates(inter):
    frac=float(np.dot(pt-mapped[i],mapped[i+1]-mapped[i])/np.dot(mapped[i+1]-mapped[i],mapped[i+1]-mapped[i])); t=ts[i]+frac*(ts[i+1]-ts[i]);crossings.append(dict(edge=rec['legacyStraightEdgeIndex'],span=rec['span'],svg=pt.tolist(),native=(q[:2]+t*delta).tolist(),t=float(t)))
 hit=model.cast(q[:3],np.r_[target,q[2]])
 rows.append(dict(svg=svg,nativeTarget=target.tolist(),visibilityAlpha=int(v[int(svg[1]*8),int(svg[0]*8)]),priorAlpha=int(o[int(svg[1]*8),int(svg[0]*8)]),hit=hit,hitSource=info(hit['face']) if hit else None,crossings=sorted(crossings,key=lambda x:x['t'])))
origin=forward(q[:2])[0]
report=dict(query=q.tolist(),originSvg=origin.tolist(),rows=rows,provenanceKeys=prov.files)
(F/'new-wedge-crossings-v1.json').write_text(json.dumps(report,indent=2));print(json.dumps(report,indent=2))
# Native crop with white origin cross and actual ray paths, source pixels untouched elsewhere.
box=(300*8,140*8,386*8,242*8);im=Image.open(F/'attack-diagonal-84-end-corner-8x-overlay.png').convert('RGB').crop(box);d=ImageDraw.Draw(im);px=origin*8-[box[0],box[1]];d.line((px[0]-8,px[1],px[0]+8,px[1]),fill='white',width=2);d.line((px[0],px[1]-8,px[0],px[1]+8),fill='white',width=2);d.text((px[0]+10,px[1]-18),'Origin',fill='white',font=ImageFont.truetype('C:/Windows/Fonts/segoeui.ttf',15));im.save(F/'attack-end-context-origin-native8x.png')
# Additional exact rays throughout the new wedge, including its near-wall side.
selected=[]
for y in range(183*8,198*8,4):
 xs=np.flatnonzero((v[y]>=200)&(o[y]<40));xs=xs[(xs>319*8)&(xs<345*8)]
 if len(xs):
  for x in np.unique([xs[0],xs[len(xs)//2],xs[-1]]):selected.append([(float(x)+.5)/8,(y+.5)/8])
outline=shapely.union_all([shapely.LineString([rec['startSvg'],rec['endSvg']]) for rec,seg in spans if rec['segmentType']=='Line'])
checks=[]
for svg in selected:
 target=g.native(svg)[0];delta=target-q[:2];line=shapely.LineString([q[:2],target]);ts=[0.,1.]
 for cell in tree.query(line,predicate='intersects'):
  coords=shapely.get_coordinates(shapely.intersection(line,source_polys[cell]));ts.extend(((coords-q[:2])@delta/(delta@delta)).tolist())
 ts=np.unique(np.round(ts,14));mapped=forward(q[:2]+ts[:,None]*delta);path=shapely.LineString(mapped);cross=shapely.intersection(path,outline)
 hit=model.cast(q[:3],np.r_[target,q[2]]);stop=model.cast(q[:3],np.r_[q[:2]+delta/np.linalg.norm(delta)*q[5],q[2]])
 checks.append(dict(svg=svg,crossingCoords=shapely.get_coordinates(cross).tolist(),hit=hit,stop=stop,stopSource=info(stop['face']) if stop else None))
(F/'new-wedge-dense-checks-v1.json').write_text(json.dumps(dict(query=q.tolist(),originSvg=origin.tolist(),count=len(checks),crossingCount=sum(bool(a['crossingCoords']) for a in checks),blockedCount=sum(a['hit'] is not None for a in checks),rows=checks),indent=2))
print('dense',len(checks),'crossed',sum(bool(a['crossingCoords']) for a in checks),'blocked',sum(a['hit'] is not None for a in checks));print('stop sources',sorted(set((a['stopSource']['object'],a['stopSource']['original']) for a in checks if a['stopSource'])))

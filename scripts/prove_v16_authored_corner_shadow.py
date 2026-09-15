"""Distinguish real wall99 corner shadow from an early misplaced stop at wall97."""
import json,gzip,hashlib
from pathlib import Path
import numpy as np
import shapely
from PIL import Image,ImageDraw,ImageFont
from audit_wall_contact_pixels import PhysicalGeometry
from tactical_alignment_composite import IndexedTriangles
from native_reference_cast import NativeReferenceModel
R=Path('E:/IcarusWorldAudit/2026-09-06/tactical-visibility-revision');F=R/'tower-v16-regression-contact';D=R/'tower-v15-v16-regression-evidence';C=R/'split-wall-family-normalized-candidate-v16';m=json.loads((F/'manifest.json').read_text());w=json.loads(gzip.decompress(Path(m['displayWarpFile']).read_bytes()));r=next(x for x in m['cases'] if x['id']=='short99-frontage' and x['side']=='attack');g=PhysicalGeometry(w,r,np.fromfile(r['prefix']+'-shadow.f32',dtype='<f4'));q=np.array(r['query']);st=IndexedTriangles(g.source,g.indices);polys=shapely.polygons(g.source[g.indices]);tree=shapely.STRtree(polys)
def forward(p):
 p=np.atleast_2d(p);i=st.find_simplex(p);t=st.transform[i];uv=np.einsum('nij,nj->ni',t[:,:2],p-t[:,2]);return np.einsum('ni,nij->nj',np.c_[uv,1-uv.sum(1)],g.target[g.indices[i]])
corner=np.array([343.401,149.313]);cn=g.native(corner)[0];delta=(cn-q[:2]);delta=delta/np.linalg.norm(delta)*15;line=shapely.LineString([q[:2],q[:2]+delta]);ts=[0.,1.]
for i in tree.query(line,predicate='intersects'):
 p=shapely.get_coordinates(shapely.intersection(line,polys[i]));ts.extend(((p-q[:2])@delta/(delta@delta)).tolist())
ts=np.unique(np.round(ts,14));points=forward(q[:2]+ts[:,None]*delta);tangent=shapely.LineString(points)
model=NativeReferenceModel(C/'split.height.bin.gz',R/'native-tactical-rays-build/Release/tactical_reference_cast.dll');prov=np.load(C/'normalized-face-provenance.npz');edge_by_face=dict(zip(prov['generatedFaceIds'].tolist(),prov['generatedEdges'].tolist()));cf=np.load(C/'correspondence.npz')['sourceFaces'];full=np.load(R/'global-ground-complete-v2/split/correspondence.npz')['sourceFaces'];orig=np.load(R/'full-height-input-v1/split/source-correspondence.npz')['sourceFaces'];meta=json.loads((R.parent/'supplemented-v2/world/split/geometry.json').read_text());starts=np.array([o['firstFace'] for o in meta['objects']]);raw=np.load(R.parent/'supplemented-v2/world/split/geometry.npz')
raw_points=raw['points'];raw_faces=raw['faces']
def hit_at(p):
 n=g.native(p)[0];hit=model.cast(q[:3],np.r_[n,q[2]])
 if hit:
  face=hit['face'];of=int(orig[full[cf[face]]]);oi=int(np.searchsorted(starts,of,side='right')-1);hit.update(displayPoint=forward(np.array(hit['point'][:2]))[0].tolist(),generatedEdge=edge_by_face.get(face),originalFace=of,object=oi,path=meta['objects'][oi]['path'],rawTriangle=raw_points[raw_faces[of]].tolist())
 return hit
contact=json.loads((R/'tower-v16-solid97-contact/contact-report.json').read_text());records=[]
for side in ['attack','defense']:
 rr=next(x for x in contact['rasterProfiles'] if x['side']==side and x['id']=='short99-frontage' and x['scale']==8);row_by_y={round((p['pointSvg'][1] if side=='attack' else w['attackToDefenseSvg']['origin'][1]-p['pointSvg'][1]),9):p for p in rr['profiles']}
 for gp in rr['geometricProfiles']:
  y=gp['pointSvg'][1] if side=='attack' else w['attackToDefenseSvg']['origin'][1]-gp['pointSvg'][1]
  if not 149.313<y<157.819:continue
  crossing=shapely.get_coordinates(shapely.intersection(tangent,shapely.LineString([[330,y],[350,y]])));assert len(crossing)==1
  x=float(crossing[0,0]);pred=343.401-x;original_normal_measurement=gp['firstClearInwardSvg'];offsets=np.arange(0.,2.005,.005);clear=g.clear(np.c_[343.401-offsets,np.full(len(offsets),y)]);measured=float(offsets[np.flatnonzero(clear)[0]]);early=hit_at([343.400,y]);left=hit_at([x-.01,y]);right=hit_at([x+.01,y]);assert early is not None and left is None and right is not None
  assert abs(early['displayPoint'][1]-149.313)<1e-8,(y,early)
  assert pred-1e-5<=measured<=pred+.00501,(pred,measured)
  records.append(dict(side=side,attackY=y,authoredCornerShadowX=x,predictedInwardShadowSvg=pred,meshFirstClearInwardSvg=measured,originalUnrestrictedNormalMeasurementSvg=original_normal_measurement,samplingExcessSvg=measured-pred,nearWallFirstHit=early,justInsideShadowHit=right,justOutsideShadowHit=left,pixelContact=row_by_y.get(round(y,9))))
summary=dict(scope=__doc__,sourceQuery=q.tolist(),authoredCorner=corner.tolist(),sourceNativeCorner=cn.tolist(),sourceNativeTangentDirection=(cn-q[:2]).tolist(),exactPiecewiseDisplayTangent=points.tolist(),samples=len(records),maximumMeshSamplingExcessSvg=max(x['samplingExcessSvg'] for x in records),minimumMeshSamplingExcessSvg=min(x['samplingExcessSvg'] for x in records),allNearWallHitsOnAuthored99=True,allCornerTangentFlanksMatch=True,geometrySamplingStepSvg=.005,rows=records)
(D/'authored99-continuous-tangent-and-pixels.json').write_text(json.dumps(summary,indent=2));print('matched',len(records),'mesh sampling excess',summary['minimumMeshSamplingExcessSvg'],summary['maximumMeshSamplingExcessSvg']);print('original blockers',sorted(set((x['nearWallFirstHit']['object'],x['nearWallFirstHit']['originalFace']) for x in records)))
# Native source pixels around the lower97 shadow, with exact crop coordinates.
font=ImageFont.truetype('C:/Windows/Fonts/segoeui.ttf',13);box=(int(340*8),int(154.5*8),int(344.5*8),int(158.5*8));im=Image.open(F/'attack-short99-frontage-8x-overlay.png').convert('RGB').crop(box);im.save(D/'attack-97-lower-shadow-unscaled-native8x.png');summary['nativeDetailCropPixels']=box;summary['nativeDetailPath']=str(D/'attack-97-lower-shadow-unscaled-native8x.png');(D/'authored99-continuous-tangent-and-pixels.json').write_text(json.dumps(summary,indent=2))




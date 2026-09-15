"""Complement nominated planes with unchanged depth profiles and closed barrier surfaces."""
import json,gzip,hashlib
from pathlib import Path
from collections import defaultdict
import numpy as np
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
from matplotlib.collections import LineCollection
from mpl_toolkits.mplot3d.art3d import Poly3DCollection
R=Path('E:/IcarusWorldAudit/2026-09-06/tactical-visibility-revision');D=R/'split-component2-source-review-v1';packet=np.load(D/'full-objects-source-packet.npz');ids=packet['originalFaceIds'];oids=packet['sourceObjectIds'];xyz=packet['sourceSvgTriangles'];native=packet['nativeTriangles'];raw=np.load(R.parent/'supplemented-v2/world/split/geometry.npz');meta=json.loads((R.parent/'supplemented-v2/world/split/geometry.json').read_text());proposal=json.loads(gzip.decompress((R/'split-connected-contour-proposals-v2/component-2.json.gz').read_bytes()));groups=defaultdict(list)
for fid,t in zip(ids[oids==5801],xyz[oids==5801]):
 fixed=np.flatnonzero(np.ptp(t,axis=0)<1e-5);key=tuple((int(i),round(float(t[:,i].mean()),5)) for i in fixed) or ('oblique',);groups[str(key)].append(int(fid))
rows=[]
for key,faces in groups.items():
 select=np.isin(ids,faces);q=xyz[select];a=native[select];rows.append(dict(group=key,originalFaces=faces,sourceSvgZBounds=[q.min((0,1)).tolist(),q.max((0,1)).tolist()],nativeBounds=[a.min((0,1)).tolist(),a.max((0,1)).tolist()],materials=[dict(index=int(m),**meta['materials'][m]) for m in np.unique(raw['material_indices'][faces])]))
(D/'wall-barrier-all-surfaces.json').write_text(json.dumps(dict(object=5801,totalFaces=76,grouping='Axis-constant coordinates within1e-5SVG or meters for display inventory only; no face selection or normalization tolerance.',groups=rows),indent=2))
# Native thin-object views highlight front/back sheets and caps, preserving all faces.
fig=plt.figure(figsize=(14,7));colors=plt.get_cmap('tab10');sel=oids==5801;bp=native[sel];bi=ids[sel];lo=bp.min((0,1));hi=bp.max((0,1))
for ai,azim in enumerate([-68,114]):
 ax=fig.add_subplot(1,2,ai+1,projection='3d')
 for gi,row in enumerate(rows):
  t=bp[np.isin(bi,row['originalFaces'])];ax.add_collection3d(Poly3DCollection(t,facecolors=[colors(gi%10)],edgecolors=['#334155'],alpha=.5,linewidths=.35))
 ax.set_xlim(lo[0],hi[0]);ax.set_ylim(lo[1],hi[1]);ax.set_zlim(lo[2],hi[2]);ax.set_box_aspect([hi[0]-lo[0],.8,hi[2]-lo[2]]);ax.view_init(elev=17,azim=azim);ax.set_xlabel('Native X, m');ax.set_yticks([lo[1],hi[1]], [f'{lo[1]:.3f}',f'{hi[1]:.3f}']);ax.set_ylabel('Y, m',labelpad=8);ax.set_zlabel('Original Z, m')
fig.suptitle('Object5801: all76 source faces, front/back sheets, beveled frame and caps\nY depth visually expanded for inspection; data coordinates and face identities unchanged.');fig.tight_layout(rect=[0,0,1,.93]);fig.savefig(D/'barrier-front-back-caps.png',dpi=160);plt.close(fig)
# Exact raw-height cross-sections show recesses and distinct front/back planes.
fig,axes=plt.subplots(4,1,figsize=(14,10));sections=[]
for ax,z in zip(axes,[.5,3.,4.5,7.2]):
 for obj,color in [(5866,'#2563eb'),(5801,'#ea580c')]:
  segs=[];owners=[]
  for fid,t in zip(ids[oids==obj],xyz[oids==obj]):
   values=t[:,2]-z;cuts=[]
   for e in range(3):
    f=(e+1)%3
    if values[e]==0:cuts.append(t[e,:2])
    if values[e]*values[f]<0:
     u=-values[e]/(values[f]-values[e]);cuts.append(t[e,:2]+u*(t[f,:2]-t[e,:2]))
   if not cuts:continue
   line=np.array([cuts[0],cuts[-1]])
   if line[:,1].max()<134. or line[:,1].min()>137.2:continue
   segs.append(line);owners.append(int(fid))
  if segs:ax.add_collection(LineCollection(segs,colors=color,linewidths=1.4,label=str(obj)))
  sections.append(dict(rawZ=z,object=obj,segmentsSourceSvg=np.array(segs).tolist(),originalFaceIds=owners))
 ax.axhline(134.959,color='#0891b2',ls='--',lw=1,label='Authored83');ax.set_xlim(389.8,425);ax.set_ylim(137.1,134.);ax.grid(alpha=.2);ax.set_title(f'Original Z={z}m; blueTowerBattery5866, orangeWallBarrier5801. Depth axis magnified.');ax.set_ylabel('Source-art Y');ax.legend(loc='upper right',fontsize=7)
axes[-1].set_xlabel('Source-art X / SVG units');fig.tight_layout();fig.savefig(D/'span83-depth-sections.png',dpi=160);plt.close(fig);(D/'span83-depth-sections.json').write_text(json.dumps(dict(scope='Actual triangle sections at raw source heights; no source ground selection or height extrusion.',sections=sections),indent=2))
# Attach material identities and descriptions grounded in the actual source geometry.
review=json.loads((D/'review.json').read_text())
for span in review['spans']:
 for p in span['planes']:
  p['materials']=[dict(index=int(m),**meta['materials'][m]) for m in np.unique(raw['material_indices'][p['originalFaceIds']])]
notes={'82/P0':'Broad side sheet plus upper edge detail; the selected raw profile is filled through most of0..7.98m.','84/P0':'Opposite broad side sheet plus upper edge detail; raw profile is filled through most of0..7.98m.','83/P0':'Front structural plane with base, central and perimeter strips around two inset regions, plus detached upper strip.','83/P1':'Twenty faces of the same building occupy the two inset regions behind P0, at sourceY134.80980 versus136.22374. RawZ2.8366..6.4276m.','83/P2':'Forty-eight trim-material faces form short repeated lower strips, rawZ2.5558..3.4639m, between inset panels and front frame. They do not form a continuous full-height wall.','83/P3':'Two slanted left-edge faces on the separate5801 plate/frame.','83/P4':'Two broad front plate faces1845022/23 on5801 atsourceY136.28691.','83/P5':'Sixteen coplanar frame faces1845066..1845081 on5801 atsourceY136.24378.','83/P6':'Two slanted right-edge faces on5801.','85/P0':'Opposite front/frame plane, including lower sheet, perimeter and diagonals around triangular inset regions.','85/P1':'Four trim-material triangles1865859..1865862 fill triangular inset regions just behind P0, rawZ2.9764..6.5292m.'}
review['geometryInterpretation']=dict(basis='Descriptions of plotted raw surfaces and bound material assignments. These do not establish actor gameplay purpose or approve a wall-family mapping.',planes=notes,barrier='Independent76-face thin framed panel covering the right region of83. Its22 nominated front/bevel faces are incomplete ownership for moving the whole connected object; back surfaces and24 cap faces remain explicit.',mappingRisk='A shared building-frame mapping must preserve these recess depths or explicitly define which depth layers belong to an authored frontage. Moving only nominated contact planes would separate attached faces. No mapping or bake is performed here.');review['additionalImages']=[str(D/x) for x in ['barrier-front-back-caps.png','span83-depth-sections.png']];(D/'review.json').write_text(json.dumps(review,indent=2));print('Depth sections and full barrier ownership ready')


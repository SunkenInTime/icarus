import json,gzip
from pathlib import Path
from collections import defaultdict
import numpy as np
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
from mpl_toolkits.mplot3d.art3d import Poly3DCollection
R=Path('E:/IcarusWorldAudit/2026-09-06/tactical-visibility-revision');D=R/'split-component2-source-review-v1';a=np.load(D/'full-objects-source-packet.npz');ids=a['originalFaceIds'];xyz=a['nativeTriangles'];sv=a['sourceSvgTriangles'];lookup={int(f):i for i,f in enumerate(ids)};inv={x['originalFace']:x for x in json.loads(gzip.decompress((D/'all-source-faces.json.gz').read_bytes()))};j=json.loads(gzip.decompress((R/'split-connected-contour-proposals-v2/component-2.json.gz').read_bytes()));pack=[]
for sid,pi in [(83,1),(83,2),(85,1)]:
 p=next(s for s in j['spans'] if s['completeSpan']==sid)['planes'][pi];panels=set(p['expandedSourceFaces']);direct=set(n for f in panels for n in inv[f]['exactEdgeNeighbors'])-panels;completed=set(direct);groups=[]
 for seed in sorted(direct):
  t=xyz[lookup[seed]];n=np.cross(t[1]-t[0],t[2]-t[0]);n/=np.linalg.norm(n);pending=[seed];seen={seed}
  while pending:
   fid=pending.pop()
   for adj in inv[fid]['exactEdgeNeighbors']:
    if adj in seen or adj in panels:continue
    q=xyz[lookup[adj]];residual=float(np.max(abs((q-t[0])@n)))
    if residual<=1e-6:seen.add(adj);pending.append(adj)
  completed.update(seen);groups.append(dict(seedFace=seed,coplanarConnectedFaces=sorted(seen),maximumPlaneResidualMeters=float(max(np.max(abs((xyz[lookup[f]]-t[0])@n)) for f in seen))))
 additional=[]
 if sid==85 and pi==1:
  # These source triangles complete the two diagonal return strips. They are
  # genuinely noncoplanar with their paired triangle, so preserve explicitly.
  for face,neighbor in [(1865863,1865864),(1865875,1865876)]:
   assert neighbor in completed and neighbor in inv[face]['exactEdgeNeighbors']
   additional.append(dict(originalFace=face,exactSharedEdgeNeighbor=neighbor,sourceNativeTriangle=xyz[lookup[face]].tolist()))
   completed.add(face)
 capids=sorted(completed);selected=np.array([lookup[f] for f in sorted(panels|completed)]);native=xyz[selected];source=sv[selected];full=np.array(sorted(panels|completed));path=D/f'span-{sid}-plane-{pi}-panels-and-returns.npz';np.savez_compressed(path,originalFaces=full,sourceNativeTriangles=native,sourceSvgTriangles=source,isPanel=np.isin(full,list(panels)))
 fig=plt.figure(figsize=(13,6));ax=fig.add_subplot(121,projection='3d');ax2=fig.add_subplot(122,projection='3d')
 for view,angle in [(ax,-75),(ax2,105)]:
  for mask,color in [(np.isin(full,list(panels)),'#2563eb'),(np.isin(full,capids),'#ea580c')]:
   view.add_collection3d(Poly3DCollection(native[mask],facecolors=[color],edgecolors=['#334155'],alpha=.45,linewidths=.3))
  lo=native.min((0,1));hi=native.max((0,1));view.set_xlim(lo[0],hi[0]);view.set_ylim(lo[1],hi[1]);view.set_zlim(lo[2],hi[2]);view.set_box_aspect([hi[0]-lo[0],max(hi[1]-lo[1],.8),hi[2]-lo[2]]);view.set_yticks([lo[1],hi[1]]);view.set_xlabel('Native X');view.set_ylabel('Native Y');view.set_zlabel('Raw Z, m');view.view_init(elev=18,azim=angle)
 fig.suptitle(f'Complete span{sid} P{pi}: blue{len(panels)}panel faces, orange{len(capids)}connected return faces\nSource coordinates unchanged; narrow depth visually expanded. Exact face IDs are in the paired packet.');fig.subplots_adjust(left=.04,right=.94,bottom=.08,top=.83,wspace=.25);image=D/f'span-{sid}-plane-{pi}-panels-and-returns.png';fig.savefig(image,dpi=160);plt.close(fig);pack.append(dict(completeSpan=sid,plane=pi,panelFaces=sorted(panels),directExactEdgeNeighborFaces=sorted(direct),returnFaces=capids,coplanarCompletionFaces=sorted(set(capids)-{x["originalFace"] for x in additional}),coplanarGroups=groups,additionalNoncoplanarDepthReturns=additional,nativeBounds=[native.min((0,1)).tolist(),native.max((0,1)).tolist()],sourceSvgZBounds=[source.min((0,1)).tolist(),source.max((0,1)).tolist()],packet=str(path),image=str(image)))
(D/'inset-panel-depth-returns.json').write_text(json.dumps(dict(scope='Exact shared-edge neighboring faces, followed only across coplanar connected triangles with<=1e-6m residual for audit grouping. Two explicitly identified noncoplanar diagonal returns are retained separately. No face is moved or selected for a bake.',groups=pack),indent=2));print([(p['completeSpan'],p['plane'],len(p['panelFaces']),len(p['returnFaces'])) for p in pack])



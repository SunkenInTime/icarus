"""Read-only Split component2 source profiles, native3D and exact neighboring faces."""
import gzip,json,hashlib
from pathlib import Path
from collections import defaultdict
import numpy as np
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
from matplotlib.collections import PolyCollection,LineCollection
from mpl_toolkits.mplot3d.art3d import Poly3DCollection
ROOT=Path('E:/IcarusWorldAudit/2026-09-06');R=ROOT/'tactical-visibility-revision';OUT=R/'split-component2-source-review-v1';OUT.mkdir(exist_ok=True)
proposal=R/'split-connected-contour-proposals-v2/component-2.json.gz';j=json.loads(gzip.decompress(proposal.read_bytes()));rawp=ROOT/'supplemented-v2/world/split/geometry.npz';raw=np.load(rawp);meta=json.loads(rawp.with_suffix('.json').read_text());projpath=ROOT/'tactical-alignment-sides-v1/split.json';A=np.array(json.loads(projpath.read_text())['nativeToAttackSvg']);colors=plt.get_cmap('tab10');records=[];allnominated=set();members=defaultdict(list)
for span in j['spans']:
 for pi,p in enumerate(span['planes']):
  for f in p['expandedSourceFaces']:allnominated.add(f);members[f].append([span['completeSpan'],pi])
objects={};triangles={};projected={};objectfaces={}
for oid in [5866,5801]:
 ob=meta['objects'][oid];ids=np.arange(ob['firstFace'],ob['firstFace']+ob['faceCount']);xyz=raw['points'][raw['faces'][ids]].copy();sv=xyz.copy();sv[:,:,:2]=xyz[:,:,:2]@A[:,:2].T+A[:,2];objects[oid]=ob;triangles[oid]=xyz;projected[oid]=sv;objectfaces[oid]=ids
# Four along-height plots and separate plane panels retain raw source Z.
for span in j['spans']:
 sid=span['completeSpan'];line=np.array(span['authoredEndpoints']);direction=line[1]-line[0];length=np.linalg.norm(direction);direction/=length
 fig,ax=plt.subplots(figsize=(13,6.5));plane_rows=[]
 for pi,p in enumerate(span['planes']):
  xyz=np.array(p['sourceClippedTrianglesSvgZ']);along=(xyz[:,:,:2]-line[0])@direction;poly=np.stack([along,xyz[:,:,2]],axis=2);label=f"P{pi} object{p['sourceObjectIndex']} | {len(p['expandedSourceFaces'])} source faces"
  ax.add_collection(PolyCollection(poly,facecolors=[colors(pi)],edgecolors=[colors(pi)],alpha=.55,linewidths=.3,label=label));bounds=[xyz.min((0,1)).tolist(),xyz.max((0,1)).tolist()];plane_rows.append(dict(plane=pi,object=p['sourceObjectIndex'],sourcePlane=p['sourcePlane'],rawZBounds=[bounds[0][2],bounds[1][2]],sourceBoundsSvgZ=bounds,originalFaceIds=p['expandedSourceFaces'],clippedTriangleSourceFaces=p['clippedTriangleSourceFaces'],sourceReasons=p['reasons'],standingContactCount=p['standingInteriorPositionCount']))
 ax.axvline(0,color='#b45309',ls='--');ax.axvline(length,color='#b45309',ls='--');ax.set_xlim(-3,length+3);ax.set_ylim(-.25,10.15);ax.set_xlabel('Along authored span, SVG units. Dashed lines are authored endpoints.');ax.set_ylabel('Original source Z, meters');ax.grid(alpha=.2);ax.legend(fontsize=8,loc='upper right');ax.set_title(f'Split component2 / complete span{sid}, legacy{span["legacyStraightEdgeIndex"]}\nAll nominated source sheets overlaid. Gaps and secondary depth layers are retained.');fig.tight_layout();path=OUT/f'span-{sid}-along-height.png';fig.savefig(path,dpi=150);plt.close(fig)
 n=len(span['planes']);fig,axes=plt.subplots(max(1,(n+1)//2),2,figsize=(13,3.5*max(1,(n+1)//2)),squeeze=False)
 for pi,p in enumerate(span['planes']):
  ax=axes.flat[pi];xyz=np.array(p['sourceClippedTrianglesSvgZ']);poly=np.stack([(xyz[:,:,:2]-line[0])@direction,xyz[:,:,2]],axis=2);ax.add_collection(PolyCollection(poly,facecolors=[colors(pi)],edgecolors=[colors(pi)],alpha=.8,linewidths=.2));ax.set_xlim(-3,length+3);ax.set_ylim(-.25,10.15);ax.grid(alpha=.2);ax.set_title(f'P{pi} object{p["sourceObjectIndex"]}, original Z{xyz[:,:,2].min():.3f}..{xyz[:,:,2].max():.3f}m',fontsize=10);ax.set_xlabel('Along span, SVG units');ax.set_ylabel('Raw Z, m')
 for ax in list(axes.flat)[n:]:ax.set_visible(False)
 fig.suptitle(f'Complete span{sid}: each distinct source plane, no merged wall extrusion');fig.tight_layout(rect=[0,0,1,.96]);plane_image=OUT/f'span-{sid}-separate-planes.png';fig.savefig(plane_image,dpi=140);plt.close(fig);records.append(dict(completeSpan=sid,legacy=span['legacyStraightEdgeIndex'],authoredEndpoints=span['authoredEndpoints'],planes=plane_rows,profileImage=str(path),separatePlanesImage=str(plane_image)))
# Full unchanged source objects, not only the nominated vertical sheets.
fig=plt.figure(figsize=(16,7));axes=[fig.add_subplot(121,projection='3d'),fig.add_subplot(122,projection='3d')]
for ax,angle in zip(axes,[-58,128]):
 for i,oid in enumerate([5866,5801]):
  xyz=triangles[oid];ax.add_collection3d(Poly3DCollection(xyz,facecolors=['#64748b' if i==0 else '#f97316'],edgecolors=['#475569' if i==0 else '#c2410c'],alpha=.10 if i==0 else .5,linewidths=.12))
 allxyz=np.concatenate(list(triangles.values()));lo=allxyz.min((0,1));hi=allxyz.max((0,1));ax.set_xlim(lo[0],hi[0]);ax.set_ylim(lo[1],hi[1]);ax.set_zlim(lo[2],hi[2]);ax.set_box_aspect(hi-lo);ax.view_init(elev=24,azim=angle);ax.set_xlabel('Native X, m');ax.set_ylabel('Native Y, m');ax.set_zlabel('Original Z, m');ax.set_title(f'Original object geometry / azimuth{angle}')
fig.suptitle('Split component2 | gray5866 TowerBattery, orange5801 WallBarrier\nNo geometry moved, faces removed, or opaque height inferred.');fig.tight_layout(rect=[0,0,1,.92]);fig.savefig(OUT/'objects-native-3d.png',dpi=160);plt.close(fig)
fig,ax=plt.subplots(figsize=(11,10))
for i,oid in enumerate([5866,5801]):
 sv=projected[oid];closed=np.concatenate([sv[:,:,:2],sv[:,:1,:2]],axis=1);ax.add_collection(LineCollection(closed,colors='#475569' if i==0 else '#ea580c',alpha=.13 if i==0 else .7,linewidths=.3 if i==0 else .6,label=f'{oid}: {objects[oid]["path"].split("/")[1]}'))
for span in j['spans']:
 p=np.array(span['authoredEndpoints']);ax.plot(*p.T,color='#0891b2',lw=2);ax.text(*p.mean(0),f' {span["completeSpan"]}',fontsize=11,color='#075985')
allxy=np.concatenate(list(projected.values()))[:,:,:2];lo=allxy.min((0,1))-2;hi=allxy.max((0,1))+2;ax.set_xlim(lo[0],hi[0]);ax.set_ylim(hi[1],lo[1]);ax.set_aspect('equal');ax.grid(alpha=.2);ax.legend(fontsize=9);ax.set_title('Unchanged source geometry under source-art affine projection\nCyan: original authored rectangle, complete span IDs. This is before displayW.');ax.set_xlabel('Source-art SVG X');ax.set_ylabel('Source-art SVG Y');fig.tight_layout();fig.savefig(OUT/'objects-source-plan.png',dpi=160);plt.close(fig)
# Exact shared edges identify neighboring source faces; no proximity welding.
face_inventory=[];neighbor_rows=[]
for oid in [5866,5801]:
 ids=objectfaces[oid];xyz=triangles[oid];edges=defaultdict(list)
 for fid,points in zip(ids,xyz):
  for e in range(3):edges[tuple(sorted((tuple(points[e]),tuple(points[(e+1)%3]))))].append(int(fid))
 adjacency=defaultdict(set)
 for ff in edges.values():
  for f in ff:adjacency[f].update(x for x in ff if x!=f)
 for fid,points,sv in zip(ids,xyz,projected[oid]):
  normal=np.cross(points[1]-points[0],points[2]-points[0]);norm=np.linalg.norm(normal);normal=normal/norm if norm else normal;kind='degenerate' if not norm else ('horizontal' if abs(normal[2])>=.98 else 'near-vertical' if abs(normal[2])<=.02 else 'oblique')
  row=dict(originalFace=int(fid),object=oid,normal=normal.tolist(),geometricOrientation=kind,rawZBounds=[float(points[:,2].min()),float(points[:,2].max())],sourceSvgBounds=[sv[:,:2].min(0).tolist(),sv[:,:2].max(0).tolist()],nominatedPlanes=members[int(fid)],exactEdgeNeighbors=sorted(adjacency[int(fid)]));face_inventory.append(row)
  if int(fid) not in allnominated and adjacency[int(fid)]&allnominated:neighbor_rows.append(row)
np.savez_compressed(OUT/'full-objects-source-packet.npz',originalFaceIds=np.concatenate(list(objectfaces.values())),sourceObjectIds=np.concatenate([np.full(len(objectfaces[o]),o) for o in [5866,5801]]),nativeTriangles=np.concatenate(list(triangles.values())),sourceSvgTriangles=np.concatenate(list(projected.values())))
(OUT/'all-source-faces.json.gz').write_bytes(gzip.compress(json.dumps(face_inventory,separators=(',',':')).encode(),mtime=0));(OUT/'adjacent-faces.json').write_text(json.dumps(dict(rule='Exact shared3Dedge adjacency only. Orientation is geometry, not a cap/wall semantic label.',faces=neighbor_rows),indent=2))
inputs=[proposal,rawp,rawp.with_suffix('.json'),projpath,Path('assets/maps/split_map.svg')];report=dict(scope=__doc__,productionMutation=False,sourceObjects=[dict(index=o,**objects[o]) for o in objects],spans=records,joins=j['joins'],allSourceFaces=len(face_inventory),nominatedSourceFaces=len(allnominated),exactAdjacentNonNominatedFaces=len(neighbor_rows),inputs=[dict(path=str(p),sha256=hashlib.sha256(p.read_bytes()).hexdigest()) for p in inputs]);(OUT/'review.json').write_text(json.dumps(report,indent=2));print('Prepared',len(records),'span profiles,',len(face_inventory),'full source faces,',len(neighbor_rows),'exact neighboring faces',OUT)

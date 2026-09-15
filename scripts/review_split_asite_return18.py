"""Read-only full-instance source review of the standing edge17/18 early contact."""
import gzip, hashlib, io, json
from pathlib import Path
import numpy as np
import shapely
import resvg_py
from PIL import Image
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
from matplotlib.collections import LineCollection
from mpl_toolkits.mplot3d.art3d import Poly3DCollection
from tactical_alignment_audit import vector_lines
from tactical_alignment_composite import explicit_warp

ROOT=Path('E:/IcarusWorldAudit/2026-09-06'); REV=ROOT/'tactical-visibility-revision'
OUT=REV/'split-asite-return18-source-review-v2'
OUT.mkdir(exist_ok=False)
rawpath=ROOT/'supplemented-v2/world/split/geometry.npz'
raw=np.load(rawpath); points=raw['points']; faces=raw['faces']
metapath=rawpath.with_suffix('.json'); meta=json.loads(metapath.read_text())
apath=ROOT/'tactical-alignment-sides-v1/split.json'; A=np.array(json.loads(apath.read_text())['nativeToAttackSvg'])
wpath=REV/'display-warps-v1/split.display-warp.json.gz'; w=json.loads(gzip.decompress(wpath.read_bytes()))
source=np.array(w['sourceNativeMeters']).reshape(-1,2)@A[:,:2].T+A[:,2]
target=np.array(w['targetAttackSvg']).reshape(-1,2); cells=np.array(w['triangles']).reshape(-1,3)
forward=explicit_warp(source,target-source,cells)
backward=explicit_warp(target,source-target,cells)
native=lambda xy:(backward.apply(np.atleast_2d(xy))-A[:,2])@np.linalg.inv(A[:,:2]).T
display=lambda xy:forward.apply(np.atleast_2d(xy)@A[:,:2].T+A[:,2])
lines=vector_lines(Path('assets/maps/split_map.svg'))
auditpath=REV/'split-remaining-standing-origins-v1/edge-17.json'; audit=json.loads(auditpath.read_text())
selected=[r for r in audit['records'] if any(a['parentBoundaryMarginMeters']>.15 and a['fiveVerticalBodyProbesClear'] for a in r['navFloorAssociations'])]
lower=np.array([67.,89.,2.]);upper=np.array([71.,94.,7.])
objects=[]; meshes={}; ids={}; local={}
for oid,o in enumerate(meta['objects']):
 lo,hi=np.array(o['boundsMeters'])
 if np.any(hi<lower) or np.any(lo>upper):continue
 ff=np.arange(o['firstFace'],o['firstFace']+o['faceCount']);tri=points[faces[ff]]
 mask=np.all(tri.max(1)>=lower,axis=1)&np.all(tri.min(1)<=upper,axis=1)
 if not mask.any():continue
 meshes[oid]=tri;ids[oid]=ff;local[oid]=ff[mask]
 objects.append(dict(index=oid,**o,localFaceIds=ff[mask].tolist(),selection='3D triangle-AABB overlap with fixed native box; no object-name filter; broadphase only'))
fullids=np.concatenate(list(ids.values())); owner=np.concatenate([np.full(len(ids[o]),o) for o in ids])
np.savez_compressed(OUT/'full-neighbor-instances.npz',originalFaceIds=fullids,sourceObjectIds=owner,nativeTriangles=points[faces[fullids]])
# Exact stored shared vertices; proximity is separately reported, never welded.
shellverts=np.unique(meshes[5857].reshape(-1,3),axis=0); shellset=set(map(tuple,shellverts))
for o in objects:
 verts=np.unique(meshes[o['index']].reshape(-1,3),axis=0)
 o['exactSharedVerticesWith5857']=[list(v) for v in set(map(tuple,verts))&shellset]
 o['nearestStoredVertexDistanceTo5857Meters']=float(min(np.linalg.norm(verts-v,axis=1).min() for v in shellverts))

def section(tris,z):
 result=[]; index=[]
 for i,t in enumerate(tris):
  d=t[:,2]-z; cuts=[t[j,:2] for j in range(3) if d[j]==0]
  for j in range(3):
   k=(j+1)%3
   if d[j]*d[k]<0:cuts.append(t[j,:2]+(t[k,:2]-t[j,:2])*(-d[j])/(d[k]-d[j]))
  if len(cuts)>=2:result.append([cuts[0],cuts[-1]]);index.append(i)
 return np.array(result).reshape(-1,2,2),np.array(index,dtype=int)

colors={5857:'#37b6ff',5853:'#ea678f',5849:'#b592ef',5854:'#59c297',5873:'#e4c05b',5874:'#f69555',142:'#ff6f45',392:'#cbdf55',5841:'#eeeeee'}
sectionrows=[]
for z in [2.,3.75,3.85,5.,6.9,7.01]:
 for oid,tris in meshes.items():
  seg,idx=section(tris,z)
  for s,i in zip(seg,idx):
   if np.all(s.max(0)>=lower[:2]) and np.all(s.min(0)<=upper[:2]):
    sectionrows.append(dict(object=oid,originalFace=int(ids[oid][i]),originalZ=z,nativeEndpoints=s.tolist(),displayedEndpoints=display(s).tolist()))

# Both actual SVG sides, with unchanged source sections and the exact valid nav rays.
reflection=np.array(w['attackToDefenseSvg']['origin'])
for side in ['attack','defense']:
 svgpath=Path('assets/maps/split_map'+('_defense' if side=='defense' else '')+'.svg')
 raster=Image.open(io.BytesIO(resvg_py.svg_to_bytes(svg_string=svgpath.read_text(),zoom=8,background='#101014'))).convert('RGB')
 bounds=np.array([[397.,49.],[418.,72.]])
 convert=lambda p: reflection-np.asarray(p) if side=='defense' else np.asarray(p)
 bb=convert(bounds);lo=bb.min(0);hi=bb.max(0)
 crop=raster.crop(tuple(np.r_[np.floor(lo*8),np.ceil(hi*8)].astype(int)))
 fig,axes=plt.subplots(1,2,figsize=(15,8))
 for ax,z in zip(axes,[3.75,3.85]):
  ax.imshow(crop,extent=[lo[0],hi[0],hi[1],lo[1]])
  for row in sectionrows:
   if row['originalZ']!=z:continue
   p=convert(row['displayedEndpoints']);ax.plot(*p.T,color=colors.get(row['object'],'#a0a0a0'),lw=1,alpha=.85)
  for r in selected:
   fr=r['frozenRay'];p=convert([fr['startSvg'],fr['expectedContactSvg'],fr['finishSvg']])
   ax.plot(*p.T,'w--',lw=1);ax.scatter(*p[0],s=25,color='white')
  for edge in [17,18]:
   p=convert(lines[edge]);ax.text(*p.mean(0),f' edge{edge}',color='white',fontsize=10)
  ax.set_xlim(lo[0],hi[0]);ax.set_ylim(hi[1],lo[1]);ax.set_aspect('equal');ax.set_title(f'{side} artwork / original Z{z:g}m\nBlue: full interior5857; other colors: all nearby source instances')
 fig.suptitle('A-site corner source review. Original source sections through existing display W; masks are not sampled.\nDashed rays are nav136 controls. This is source context, not a rendered cone or a proposed correction.');fig.tight_layout(rect=[0,0,1,.93]);fig.savefig(OUT/f'{side}-actual-svg-context.png',dpi=140);plt.close(fig)

fig=plt.figure(figsize=(16,8))
for k,az in enumerate([-55,130]):
 ax=fig.add_subplot(1,2,k+1,projection='3d')
 for oid in [5857,5853,5849,5854,5873,5874,142,392,5841]:
  if oid not in meshes:continue
  ax.add_collection3d(Poly3DCollection(meshes[oid],facecolors=colors[oid],edgecolors=colors[oid],alpha=.13 if oid in [5849,5853,5854] else .38,linewidths=.15))
 ax.set_xlim(52,71);ax.set_ylim(80,94);ax.set_zlim(-.5,11);ax.set_box_aspect([19,14,11.5]);ax.view_init(25,az);ax.set_xlabel('Native X m');ax.set_ylabel('Native Y m');ax.set_zlabel('Original Z m')
fig.suptitle('Unmodified full corner instances. Blue5857 interior, pink5853 exterior, purple5849 exterior, green5854 floor\nYellow5873/orange5874 backing, bracket142/monitor392/5841 retained. Plot axes crop distant extents; packet stores full instances.');fig.tight_layout(rect=[0,0,1,.93]);fig.savefig(OUT/'full-neighbor-source-3d.png',dpi=150);plt.close(fig)

# Every shell face remains individually attributable, including caps and oblique joins.
inventory=[]
for fid,t in zip(ids[5857],meshes[5857]):
 n=np.cross(t[1]-t[0],t[2]-t[0]);length=np.linalg.norm(n)
 inventory.append(dict(originalFace=int(fid),normal=(n/length if length else n).tolist(),originalXYZ=t.tolist(),rawZBounds=[float(t[:,2].min()),float(t[:,2].max())]))
fig,axes=plt.subplots(1,2,figsize=(15,6))
for ax,axis,name in zip(axes,[1,0],['Return x69: along native Y','Top shell: along native X']):
 tri=meshes[5857];normal=np.cross(tri[:,1]-tri[:,0],tri[:,2]-tri[:,0]);n=np.linalg.norm(normal,axis=1);keep=(n>0)&(np.abs(normal[:,1-axis])>.98*n)
 from matplotlib.collections import PolyCollection
 poly=tri[keep][:,:,[axis,2]];ax.add_collection(PolyCollection(poly,facecolors='#37b6ff',edgecolors='#175f85',alpha=.45,linewidths=.4));ax.autoscale();ax.axhline(3.75,color='#c53030',ls='--');ax.axhline(3.85,color='#b45309',ls=':');ax.set_title(name+' / full original finite profiles');ax.set_ylabel('Original Z m');ax.grid(alpha=.2)
fig.tight_layout();fig.savefig(OUT/'shell-original-height-profiles.png',dpi=150);plt.close(fig)
inputs=[rawpath,metapath,apath,wpath,auditpath,Path('assets/maps/split_map.svg'),Path('assets/maps/split_map_defense.svg'),Path(__file__)]
report=dict(scope=__doc__,productionMutation=False,geometricSelectionBoundsMeters=[lower.tolist(),upper.tolist()],objects=objects,shell5857Faces=inventory,sections=sectionrows,standingFixtures=selected,authoredEdges={str(i):lines[i].tolist() for i in range(15,23)},inputs=[dict(path=str(p),sha256=hashlib.sha256(p.read_bytes()).hexdigest()) for p in inputs],caveats=['Source sections show geometric bounds without material alpha sampling.','Raw nav Z2.1 is10cm above main source floor2.0; original standing hypotheses3.75 and3.85 are displayed separately.','Nearby-instance admission is only a geometric broadphase, not a role classification or permission to move every object.','No mapping declaration, bake, or live-game certification is produced.'])
(OUT/'report.json').write_text(json.dumps(report,indent=2));print(OUT, len(objects),len(fullids))

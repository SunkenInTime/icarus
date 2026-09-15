"""Retain all orientations when inspecting apparent gaps in the interior shell."""
import hashlib,json
from pathlib import Path
import numpy as np
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
from matplotlib.collections import PolyCollection
from mpl_toolkits.mplot3d.art3d import Poly3DCollection
ROOT=Path('E:/IcarusWorldAudit/2026-09-06');REV=ROOT/'tactical-visibility-revision';OUT=REV/'split-asite-return18-source-review-v2'
p=ROOT/'supplemented-v2/world/split/geometry.npz';raw=np.load(p);m=json.loads(p.with_suffix('.json').read_text());o=m['objects'][5857];ids=np.arange(o['firstFace'],o['firstFace']+o['faceCount']);tri=raw['points'][raw['faces'][ids]]
n=np.cross(tri[:,1]-tri[:,0],tri[:,2]-tri[:,0]);norm=np.linalg.norm(n,axis=1);normal=np.divide(n,norm[:,None],out=np.zeros_like(n),where=norm[:,None]>0)
fig,axes=plt.subplots(1,2,figsize=(16,6));rows=[]
for ax,planeaxis,threshold,title in zip(axes,[0,1],[68.9,90.9],['Return: all faces entirely at native X >68.9','Top: all faces entirely at native Y >90.9']):
 keep=tri[:,:,planeaxis].min(1)>threshold;along=1-planeaxis
 primary=keep&(abs(normal[:,planeaxis])>.98);caps=keep&~primary
 for selected,color,label in [(primary,'#38a5d9','Near-vertical surfaces'),(caps,'#f08b35','Other orientations: actual caps / floor / bevel geometry')]:
  ax.add_collection(PolyCollection(tri[selected][:,:,[along,2]],facecolors=color,edgecolors=color,alpha=.6,linewidths=.3,label=label))
 ax.autoscale();ax.grid(alpha=.2);ax.set_title(title+'\nNo normal-based face exclusion');ax.set_xlabel('Native '+('Y' if along else 'X')+' m');ax.set_ylabel('Original Z m');ax.legend(fontsize=7)
 rows.append(dict(planeAxis=planeaxis,strictMinimumNativeCoordinate=threshold,allOriginalFaces=ids[keep].tolist(),primaryOrientationFaces=ids[primary].tolist(),otherOrientationFaces=ids[caps].tolist()))
fig.suptitle('Apparent white bands in the earlier normal-filtered plot are occupied by retained source depth faces.\nThis projected union does not infer opacity at every depth or authorize filling any source opening.');fig.tight_layout(rect=[0,0,1,.9]);fig.savefig(OUT/'shell-all-orientation-profiles.png',dpi=150);plt.close(fig)

probes=[]
for x,z in [(60,2.69),(60,5.13),(60,5.1),(60,5.16),(68.8,2.69)]:
 a=np.array([x,90.5,z]);dr=np.array([0,1,0]);e1=tri[:,1]-tri[:,0];e2=tri[:,2]-tri[:,0];h=np.cross(dr,e2);det=np.einsum('ij,ij->i',e1,h);valid=abs(det)>1e-12;inv=np.divide(1,det,out=np.zeros_like(det),where=valid);q0=a-tri[:,0];u=np.einsum('ij,ij->i',q0,h)*inv;q=np.cross(q0,e1);v=q@dr*inv;t=np.einsum('ij,ij->i',e2,q)*inv;ix=np.flatnonzero(valid&(u>=0)&(v>=0)&(u+v<=1)&(t>=0)&(t<=1))
 assert len(ix)>0
 probes.append(dict(originalStart=a.tolist(),originalEnd=(a+dr).tolist(),hits=[dict(originalFace=int(ids[i]),point=(a+t[i]*dr).tolist(),normal=normal[i].tolist(),originalXYZ=tri[i].tolist()) for i in ix]))
fig=plt.figure(figsize=(15,7))
for k,az in enumerate([-40,140]):
 ax=fig.add_subplot(1,2,k+1,projection='3d');selected=tri[:,:,1].min(1)>90.9
 for primary,color,alpha in [(True,'#389cd0',.35),(False,'#ee7925',.8)]:
  choose=selected&((abs(normal[:,1])>.98)==primary);ax.add_collection3d(Poly3DCollection(tri[choose],facecolors=color,edgecolors=color,alpha=alpha,linewidths=.25))
 ax.set_xlim(53,69);ax.set_ylim(90.9,91.12);ax.set_zlim(1.9,7.1);ax.set_box_aspect([16,3,5.2]);ax.view_init(22,az);ax.set_xlabel('Native X m');ax.set_ylabel('Native Y m, exaggerated depth');ax.set_zlabel('Original Z m')
fig.suptitle('Full top-sheet relief: original positions with depth visually exaggerated by axis aspect only.\nOrange faces close the diagonal depth transition and lower bevel; source coordinates in the packet are unchanged.');fig.tight_layout(rect=[0,0,1,.92]);fig.savefig(OUT/'top-sheet-depth-caps-3d.png',dpi=150);plt.close(fig)
report=dict(scope=__doc__,profileSelections=rows,geometricRayProbes=probes,interpretation='Earlier normal-filtered profile was not a coverage proof. These five source rays hit original depth faces; retain those exact faces in a connected mapping, with no extrusion or height infill.',inputs=[dict(path=str(q),sha256=hashlib.sha256(q.read_bytes()).hexdigest()) for q in [p,p.with_suffix('.json'),Path(__file__)]])
(OUT/'profile-cap-review.json').write_text(json.dumps(report,indent=2));print('PASS',len(probes),'original source depth-contact probes')

import json,gzip
from pathlib import Path
import numpy as np
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
R=Path('E:/IcarusWorldAudit/2026-09-06/tactical-visibility-revision');D=R/'split-component2-source-review-v1';j=json.loads(gzip.decompress((R/'split-connected-contour-proposals-v2/component-2.json.gz').read_bytes()));by={s['completeSpan']:s for s in j['spans']};rows=[];fig,axes=plt.subplots(1,4,figsize=(14,6))
for ax,join in zip(axes,j['joins']):
 a,b=join['leftSpan'],join['rightSpan'];lp=by[a]['planes'][0];rp=by[b]['planes'][0];p=np.linalg.solve([lp['sourcePlane']['normal'],rp['sourcePlane']['normal']],[lp['sourcePlane']['offset'],rp['sourcePlane']['offset']]);record=dict(leftSpan=a,rightSpan=b,sourcePlanCorner=p.tolist(),authoredCorner=join['targetSvg'],shiftSvg=(np.array(join['targetSvg'])-p).tolist(),planeContacts=[])
 for index,(span,plane) in enumerate([(a,lp),(b,rp)]):
  tangent=np.array(plane['sourcePlane']['tangent']);goal=p@tangent;contacts=[]
  for fid,t in zip(plane['clippedTriangleSourceFaces'],np.array(plane['sourceClippedTrianglesSvgZ'])):
   d=t[:,:2]@tangent-goal;cuts=[]
   for e in range(3):
    k=(e+1)%3
    if abs(d[e])<1e-8:cuts.append(float(t[e,2]))
    if d[e]*d[k]<0:
     u=-d[e]/(d[k]-d[e]);cuts.append(float(t[e,2]+u*(t[k,2]-t[e,2])))
   if cuts:
    lo,hi=min(cuts),max(cuts);contacts.append(dict(originalFace=int(fid),rawZInterval=[lo,hi]));ax.plot([index,index],[lo,hi],color=['#2563eb','#ea580c'][index],lw=6,alpha=.5)
  record['planeContacts'].append(dict(span=span,plane=0,contacts=contacts))
 ax.set_xlim(-.6,1.6);ax.set_ylim(-.25,8.2);ax.set_xticks([0,1],[str(a),str(b)]);ax.set_ylabel('Original source Z, m');ax.set_title(f'Corner{a}/{b}\nsource[{p[0]:.5f},{p[1]:.5f}]',fontsize=10);ax.grid(alpha=.2);rows.append(record)
fig.suptitle('Actual incident source-plane sections at all four main-frame corners\nEach bar retains its original triangle ownership; no vertical gap is filled.');fig.tight_layout(rect=[0,0,1,.9]);fig.savefig(D/'source-corner-height-extents.png',dpi=150);plt.close(fig);(D/'source-corner-height-extents.json').write_text(json.dumps(dict(scope='Intersection of each actual primary-plane clipped triangle with the shared source corner line. Zero comparison tolerance1e-8SVG used only for reporting source boundary arithmetic.',corners=rows),indent=2));print('4 source corner height packets')

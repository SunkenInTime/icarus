"""Show exact source instances encountered by the frozen Ascent prop-top ray."""
import json
import hashlib
from pathlib import Path
import numpy as np
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
from mpl_toolkits.mplot3d.art3d import Poly3DCollection
from audit_split_floor_roles import ROOT,REV

def main():
    out=REV/'ascent-audited-floor-role-proposals-v1'
    row=next(r for r in json.loads((ROOT/'completeness/combined-manifest-release-inputs-v2.json').read_text()) if r['map']=='ascent')
    folder=Path(row['combinedWorldFolder']);meta=json.loads((folder/'geometry.json').read_text());raw=np.load(folder/'geometry.npz')
    cases=json.loads((out/'boundary-fixtures.json').read_text())['cases'];case=next(c for c in cases if c['id']=='object-4153-explicit-top-2')
    objects=[];meshes=[]
    for index,color in [(4153,'#2563eb'),(4152,'#60a5fa'),(4121,'#f97316'),(4408,'#a16207'),(7522,'#94a3b8')]:
        obj=meta['objects'][index];mesh=raw['points'][raw['faces'][obj['firstFace']:obj['firstFace']+obj['faceCount']]]
        objects.append(dict(sourceObjectIndex=index,color=color,sourceObject=obj));meshes.append(mesh)
    bounds=np.concatenate([m.reshape(-1,3) for m in meshes]);low,high=bounds.min(axis=0),bounds.max(axis=0)
    fig=plt.figure(figsize=(14,6))
    for slot,azimuth in enumerate((-55,125),1):
        ax=fig.add_subplot(1,2,slot,projection='3d')
        for obj,mesh in zip(objects,meshes):ax.add_collection3d(Poly3DCollection(mesh,facecolors=obj['color'],edgecolors='#334155',linewidths=.08,alpha=.5 if obj['sourceObjectIndex']==7522 else .9))
        q=case['query'];origin=np.array(q[:3]);end=origin+np.r_[np.array(q[3:5])*.8,0]
        ax.plot(*np.array([origin,end]).T,color='#dc2626',linewidth=2);ax.scatter(*origin,color='#dc2626',s=30)
        ax.set_xlim(low[0],high[0]);ax.set_ylim(low[1],high[1]);ax.set_zlim(low[2],high[2]);ax.set_box_aspect(high-low);ax.view_init(20,azimuth)
        ax.set_xlabel('Native X, m');ax.set_ylabel('Native Y, m');ax.set_zlabel('Z, m')
    fig.suptitle('Ascent exact prop cluster at the unresolved outgoing top ray\n4153 blue crate; 4152 light-blue adjoining crate; 4121 orange fruit top; 4408 brown pallet; 7522 gray cloth blocker')
    fig.tight_layout();fig.savefig(out/'raised-neighbor-source.png',dpi=150);plt.close(fig)
    (out/'raised-neighbor-source.json').write_text(json.dumps(dict(sourceGeometrySha256=meta['geometrySha256'],fixtureSha256=hashlib.sha256((out/'boundary-fixtures.json').read_bytes()).hexdigest(),case=case['id'],objects=objects,scope='Exact original source objects. New neighbor roles remain unassigned pending source visual review.'),indent=2))
if __name__=='__main__':main()

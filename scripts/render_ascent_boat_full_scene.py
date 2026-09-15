"""Render source-confirmed standing differences with their actual receiver."""
import json
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
from matplotlib.collections import LineCollection
import numpy as np
from shapely import box
from audit_null_material_receiver_scope import source_receiver
from audit_tactical_target_rays import ReferenceModel
from prepare_ascent_connected_corners import ROOT,REV,OUT

def main():
    r=json.loads((OUT/'boat-208-full-scene-standing-review.json').read_text());q=max(r['changedQueries'],key=lambda x:x['receiverDifferenceMeters']);a,b=np.array(q['query']);z=a[2];source=ReferenceModel(REV/'full-height-input-v1/ascent/ascent.height.bin.gz');tri=source.arrays['vertices'][source.arrays['faces']];lo=np.minimum(a[:2],np.array(q['otherHit']['point'])[:2])-1;hi=np.maximum(a[:2],np.array(q['otherHit']['point'])[:2])+1;ids=np.flatnonzero((tri[:,:,2].min(1)<=z)&(tri[:,:,2].max(1)>=z)&np.all(tri[:,:,:2].min(1)<=hi,axis=1)&np.all(tri[:,:,:2].max(1)>=lo,axis=1));segments=[]
    for t in tri[ids]:
        points=[]
        for p,v in zip(t,np.roll(t,-1,axis=0)):
            if (p[2]-z)*(v[2]-z)<0:points.append(p[:2]+(v[:2]-p[:2])*(z-p[2])/(v[2]-p[2]))
        if len(points)==2:segments.append(points)
    receiver=source_receiver(REV,'ascent').intersection(box(*lo,*hi));fig,axes=plt.subplots(1,2,figsize=(13,6))
    for p in getattr(receiver,'geoms',[receiver]):
        if p.geom_type!='Polygon':continue
        axes[0].fill(*np.array(p.exterior.coords).T,color='#ddd3bd',alpha=.6)
        for hole in p.interiors:axes[0].fill(*np.array(hole.coords).T,color='white')
    axes[0].add_collection(LineCollection(segments,color='#36454f',linewidth=.7));old=np.array(q['originalHit']['point']);other=np.array(q['otherHit']['point']);axes[0].plot(*np.array([a[:2],other[:2]]).T,color='#0077b6',lw=2);axes[0].plot(*np.array([old[:2],other[:2]]).T,color='#e76f51',lw=4,label='Newly visible receiver: 1.142 m');axes[0].scatter(*a[:2],color='#0077b6',s=50,label='Standing source-floor pose');axes[0].scatter(*old[:2],color='#e76f51',s=40,label='Original boat stop');axes[0].scatter(*other[:2],color='black',s=40,label='Backing wall stop');axes[0].set_xlim(lo[0],hi[0]);axes[0].set_ylim(lo[1],hi[1]);axes[0].set_aspect('equal');axes[0].legend(fontsize=8);axes[0].set_title(f'Actual source section at standing eye Z={z:.4f} m');axes[0].set_xlabel('Native X, m');axes[0].set_ylabel('Native Y, m')
    values=np.array([x['receiverDifferenceMeters'] for x in r['changedQueries']]);axes[1].hist(values,bins=50,color='#0077b6');axes[1].set_xlabel('Changed painted receiver length, m');axes[1].set_ylabel('Rays');axes[1].set_title('Full-scene standing control: 44,400 rays\n20,117 changes above 1 mm within SVG receiver');fig.tight_layout();fig.savefig(OUT/'boat-208-full-scene-standing-review.png',dpi=180);plt.close(fig)

if __name__=='__main__':main()

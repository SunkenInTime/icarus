"""Explain rendered wall interruptions using original source-height sections."""
import json
from pathlib import Path
import numpy as np
import matplotlib.pyplot as plt
from matplotlib.collections import LineCollection
from prepare_ascent_connected_corners import ROOT,REV
from native_compact_wall_profiles import sha

folder=REV/'ascent-connected-component5-candidate-v5';binding=json.loads((folder/'bindings.json').read_text());f=binding['families'][0];rows=[];fig,axes=plt.subplots(2,2,figsize=(12,7));meta=json.loads((ROOT/'supplemented-v2/world/ascent/geometry.json').read_text());starts=np.asarray([o['firstFace'] for o in meta['objects']])
for col,span in enumerate([144,145]):
    s=next(x for x in f['reviewedAuthoredSpans'] if x['completeSpan']==span);a=np.asarray(s['startSvg']);b=np.asarray(s['endSvg']);d=b-a;length=np.linalg.norm(d);t=d/length;n=np.array([-t[1],t[0]])
    for ri,z in enumerate([1.75,2.75]):
        data=np.load(folder/f'original-source-sections-height-{z:g}.npz');seg=data['segments'];normal=(seg-a)@n;along=(seg-a)@t;eligible=(abs(normal).max(1)<1e-7)&(along.max(1)>=0)&(along.min(1)<=length);ids=np.flatnonzero(eligible);intervals=sorted([(max(0.,float(along[i].min())),min(length,float(along[i].max())),int(data['originalSourceFaces'][i])) for i in ids]);union=[]
        for lo,hi,face in intervals:
            if union and lo<=union[-1][1]+1e-10:union[-1][1]=max(union[-1][1],hi)
            else:union.append([lo,hi])
        gaps=[];position=0.
        for lo,hi in union:
            if lo-position>1e-7:gaps.append([position,lo])
            position=max(position,hi)
        if length-position>1e-7:gaps.append([position,length])
        # The1e-10 endpoint join is recorded only for display of the interval
        # union, never a blocker bake. All raw section intervals remain saved.
        record=dict(span=span,relativeControlHeight=z,sourceAlignedSections=len(ids),sourceObjectIds=sorted(set(np.searchsorted(starts,data['originalSourceFaces'][ids],side='right')-1)),intervals=[dict(start=lo,end=hi,originalSourceFace=face) for lo,hi,face in intervals],positiveGaps=[dict(startAlongSvg=lo,endAlongSvg=hi,lengthSvg=hi-lo,endpointsSvg=[(a+t*lo).tolist(),(a+t*hi).tolist()]) for lo,hi in gaps]);record['sourceObjectIds']=[int(i) for i in record['sourceObjectIds']];rows.append(record)
        ax=axes[ri,col];ax.plot([0,length],[0,0],color='black',lw=8,label='Authored span');ax.add_collection(LineCollection([[[lo,0],[hi,0]] for lo,hi in union],colors='#0b8b6a',linewidths=5));ax.scatter([p for g in gaps for p in g],[0]*(len(gaps)*2),color='#d76c28',s=25);ax.set_xlim(-.25,length+.25);ax.set_ylim(-.15,.3);ax.set_yticks([]);ax.set_title(f'Span {span}, control height {z:g} m: {len(gaps)} source gaps');ax.set_xlabel('Distance along authored span (SVG units)')
        for lo,hi in gaps:
            if hi-lo>.01:ax.annotate(f'{hi-lo:.3f}',((lo+hi)*.5,0),xytext=((lo+hi)*.5,.11),ha='center',fontsize=8,arrowprops=dict(arrowstyle='-',lw=.6))
fig.suptitle('Original source profiles leave openings on the authored line\nGreen: actual opaque source sections. Orange endpoints: preserved gaps.');fig.tight_layout();fig.savefig(folder/'preserved-profile-gaps.png',dpi=160);plt.close(fig)
report=dict(rows=rows,sourcePackSha256=binding['sourcePackSha256'],bindingsSha256=sha(folder/'bindings.json'),scriptSha256=sha(Path(__file__)),scope='Original source sections at the exact control heights, independently mapped through declared regions. Alignment guard1e-7 SVG and display-only interval join1e-10 SVG are explicit; raw face-bound intervals are retained. This identifies height-profile gaps, not arbitrary nearby-ray clearance.')
(folder/'preserved-profile-gaps.json').write_text(json.dumps(report,indent=2)+'\n');print([(r['span'],r['relativeControlHeight'],[(x['startAlongSvg'],x['endAlongSvg']) for x in r['positiveGaps']]) for r in rows])

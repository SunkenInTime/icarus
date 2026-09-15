"""Show actual source-support sections beside changed tactical ray paths."""
import json
import numpy as np
import shapely
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
from probe_source_floor_regressions import load_support
from audit_split_floor_roles import REV

def main(name,case_id):
    directory=REV/f'{name}-audited-floor-role-proposals-v1'
    fixtures=json.loads((directory/'boundary-fixtures.json').read_text())
    fixture=next(c for c in fixtures['cases'] if c['id']==case_id)
    result=next(c for c in json.loads((directory/'boundary-regressions.json').read_text())['cases'] if c['id']==case_id)
    support=load_support(REV,name,True)
    direction=np.array(fixture['query'][3:5]);distance=fixture['query'][5]
    fig,axes=plt.subplots(3,1,figsize=(13,11),sharex=True)
    for ax,sample in zip(axes,result['samples']):
        origin=np.array(sample['origin']); line=shapely.LineString([origin[:2],origin[:2]+direction*distance])
        ids=support.tree.query(line,predicate='intersects')
        for cell in ids[support.source_ids[ids]>=0]:
            coordinates=shapely.get_coordinates(line.intersection(support.original_polygons[cell]))
            if len(coordinates)<2:continue
            t=(coordinates-origin[:2])@direction
            z=coordinates@support.planes[cell,:2]+support.planes[cell,2]
            ax.plot(t,z,color='#94a3b8',alpha=.5,linewidth=.7)
        for key,color,label in [('before','#dc2626','Before eye path'),('proposedRoles','#059669','Proposed eye path')]:
            previous=None
            for piece in sample[key]['pieces']:
                t=np.array([piece['start'],piece['end']]);z=np.array(piece['ground'])+1.75
                ax.plot(t,z,color=color,linewidth=1.7,label=label if previous is None else None)
                if previous is not None:ax.plot([previous[0],t[0]],[previous[1],z[0]],color=color,linestyle=':',linewidth=.8)
                previous=(t[1],z[1])
            hit=sample[key]['hit']
            if hit:ax.scatter(sample[key]['distanceMeters'],hit['point'][2],color=color,marker='x',s=70,zorder=5)
        ax.axhline(origin[2],color='#2563eb',linestyle='--',linewidth=1,label='Original horizontal eye')
        ax.set_title(f"Lateral offset {sample['lateralOffsetMeters']:+.2f} m. Before {sample['before']['distanceMeters']:.4f} m, proposed {sample['proposedRoles']['distanceMeters']:.4f} m")
        ax.set_ylabel('Native height, m');ax.grid(alpha=.15);ax.legend(fontsize=8)
        lo=min(min(p['ground']) for key in ('before','proposedRoles') for p in sample[key]['pieces'])-.3
        hi=max(max(p['ground'])+1.75 for key in ('before','proposedRoles') for p in sample[key]['pieces'])+.5
        ax.set_ylim(lo,hi);ax.set_xlim(0,distance)
    axes[-1].set_xlabel('Physical XY distance along frozen ray, m')
    fig.suptitle(f'{name}: {case_id}\nGray = admitted original source support section, no source geometry edits. Ground-following rays deliberately change vertical path.')
    fig.tight_layout();output=directory/f'{case_id}-sections.png';fig.savefig(output,dpi=140);plt.close(fig);print(output)

if __name__=='__main__':
    main('icebox','object-4556-low-to-high')
    main('ascent','object-4153-explicit-top-2')

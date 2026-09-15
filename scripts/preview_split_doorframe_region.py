"""Source-only mapped doorway preview and independent barycentric area check."""
import gzip,json
import numpy as np
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
from matplotlib.collections import LineCollection
from shapely.geometry import Polygon
from shapely.ops import unary_union
from declare_split_doorframe_region import declaration,REV
from build_split_normalized_wall_families import ROOT,cut
from authored_region_cells import region_fragments
from tactical_alignment_composite import explicit_warp
from render_split_remaining_corner_families import sections

def main():
    region=declaration();source=np.array(region['sourceVerticesSvg']);target=np.array(region['targetVerticesSvg']);cells=np.array(region['triangles'])
    w=json.loads(gzip.decompress((REV/'display-warps-v1/split.display-warp.json.gz').read_bytes()));m=np.column_stack((w['projection']['axisU'],w['projection']['axisV']));o=np.array(w['projection']['origin']);s=np.array(w['sourceNativeMeters']).reshape(-1,2)@m.T+o;t=np.array(w['targetAttackSvg']).reshape(-1,2);unwarp=explicit_warp(t,s-t,np.array(w['triangles']).reshape(-1,3))
    raw=np.load(ROOT/'supplemented-v2/world/split/geometry.npz');ids=region['reviewedSourceFaces'];tri=raw['points'][raw['faces'][ids]].copy();tri[:,:,:2]=tri[:,:,:2]@m.T+o
    mapped=[];rows=[]
    for fid,xyz in zip(ids,tri):
        data=np.column_stack((xyz,np.eye(3)));inside,outside=cut(list(data),region['box']);parts=[np.array(x) for x in outside]
        if len(inside)>=3:parts.extend(x[0] for x in region_fragments(np.array(inside),region,unwarp))
        polygons=[Polygon(x[:,4:6]).convex_hull for x in parts];union=unary_union(polygons)
        rows.append(dict(originalFace=fid,unionArea=union.area,sumArea=sum(x.area for x in polygons),error=abs(union.area-.5)))
        for part in parts:
            for i in range(1,len(part)-1):mapped.append(part[[0,i,i+1],:3])
    mapped=np.array(mapped);fig,axes=plt.subplots(2,3,figsize=(17,11))
    for i,points in enumerate([source,target]):
        ax=axes[0,i];ax.triplot(points[:,0],points[:,1],cells,color='#64748b',lw=.6);ax.scatter(points[:,0],points[:,1],s=8);ax.set_xlim(338,350);ax.set_ylim(154,147);ax.set_aspect('equal');ax.set_title(['Declared source cells','Declared displayed cells'][i]);ax.grid(alpha=.2)
    axes[0,2].axis('off');axes[0,2].text(0,1,'One region moves the near jamb and its rail.\nNo faces or height coverage are added.\n\nDistant jamb: unchanged.\nCentral doorway: remains open.\n\nCells may collapse wall depth.\nNo cell reverses orientation.\nSource partition checked independently\nusing barycentric polygon unions.',va='top',fontsize=13)
    coverage=json.loads(gzip.decompress((REV/'all-map-wall-span-coverage-v1/split/attack.coverage.json.gz').read_bytes()))
    for ax,z in zip(axes[1],[8.25,10.05,10.3]):
        for label,mesh,color in [('Original DoorFrame',tri,'#dc2626'),('Mapped DoorFrame',mapped,'#16a34a')]:
            lines,_=sections(mesh,z);ax.add_collection(LineCollection(lines,colors=color,lw=2,label=label))
        for span in coverage['spans']:
            if span['legacyStraightEdgeIndex'] in [96,97] or span['span']==99:ax.plot(*np.array([span['startSvg'],span['endSvg']]).T,color='#111827',lw=2)
        ax.set_xlim(340,347);ax.set_ylim(152.5,147.5);ax.set_aspect('equal');ax.grid(alpha=.2);ax.set_title(f'Absolute source Z={z}m');ax.legend(fontsize=8)
    fig.suptitle('Declared continuous jamb mapping, source preview before pack bake. Black is authored wall.',fontsize=13);fig.tight_layout();out=REV/'split-doorframe-attachment-review-v1';fig.savefig(out/'region-source-preview.png',dpi=160);plt.close(fig)
    report=dict(sourceRows=rows,maximumSourceUnionError=max(r['error'] for r in rows),maximumOverlap=max(r['sumArea']-r['unionArea'] for r in rows),previewTriangles=len(mapped));(out/'region-source-partition-preview.json').write_text(json.dumps(report,indent=2));print({k:v for k,v in report.items() if k!='sourceRows'})

if __name__=='__main__':main()

"""Check local opening-frame mapping against its shared wall and remote doorway."""
import gzip,json
import numpy as np
import shapely
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
from matplotlib.collections import LineCollection
from build_split_connected_tower import REV
from declare_split_connected_mid_region import declaration as connected_mid
from declare_split_local_opening_frame_region import declaration
from authored_region_cells import region_fragments,barycentric
from build_split_normalized_wall_families import cut
from tactical_alignment_composite import explicit_warp
from render_split_remaining_corner_families import sections


def main():
    parent=connected_mid();family=declaration(parent);out=REV/'split-local-opening-frame-region-proposal-v1';out.mkdir(exist_ok=True)
    (out/'region-declaration.json').write_text(json.dumps(family,indent=2))
    raw=np.load(REV/'split-component7-opening-frame-review-v1/tower-opening-frame-and-upper-attachments-full-source.npz')
    original=raw['trianglesSvgSourceZ'][raw['sourceObjectIds']==6962]
    w=json.loads(gzip.decompress((REV/'display-warps-v1/split.display-warp.json.gz').read_bytes()))
    a=np.column_stack((w['projection']['axisU'],w['projection']['axisV']));s=np.array(w['sourceNativeMeters']).reshape(-1,2)@a.T+w['projection']['origin'];t=np.array(w['targetAttackSvg']).reshape(-1,2)
    unwarp=explicit_warp(t,s-t,np.array(w['triangles']).reshape(-1,3));forward=explicit_warp(s,t-s,np.array(w['triangles']).reshape(-1,3));mapped=[]
    for tri in original:
        inside,outside=cut(list(np.column_stack((tri,np.eye(3)))),family['box']);parts=[np.array(p) for p in outside]
        if len(inside)>=3:parts.extend(p for p,_,_ in region_fragments(np.array(inside),family,unwarp))
        for part in parts:mapped.extend(part[[0,j,j+1],:3] for j in range(1,len(part)-1))
    mapped=np.array(mapped);mapped[:,:,:2]=forward.apply(mapped[:,:,:2].reshape(-1,2)).reshape(-1,3,2)
    fig,axes=plt.subplots(2,4,figsize=(18,10))
    for column,z in enumerate([6.75,9.75,12.75,16.75]):
        for row,bounds in enumerate([[127,178,136,185],[127,193,136,212]]):
            ax=axes[row,column]
            for tri,color,label in [(original,'#dc2626','Original source'),(mapped,'#16a34a','Proposed mapping')]:
                lines,_=sections(tri,z);ax.add_collection(LineCollection(lines,colors=color,lw=1.6,label=label))
            if row==0:ax.axhline(180.147,color='#111827',lw=1,label='Authored199')
            ax.set_xlim(bounds[0],bounds[2]);ax.set_ylim(bounds[3],bounds[1]);ax.set_aspect('equal');ax.grid(alpha=.2);ax.set_title(f'Absolute source Z {z:g} m');ax.legend(fontsize=7)
    fig.suptitle('6962 opening frame: local frontage joins199; distant lower doorway stays in its original position.\nOriginal height profiles retained. No extrusion; no pack bake.');fig.tight_layout(rect=[0,0,1,.94]);fig.savefig(out/'local-front-and-remote-doorway.png',dpi=160);plt.close(fig)
    def evaluate(d,points):
        src=np.array(d['sourceVerticesSvg']);dst=np.array(d['targetVerticesSvg']);cells=np.array(d['triangles']);tree=shapely.STRtree(shapely.polygons(src[cells]));values=[]
        for point in points:
            hit=tree.query(shapely.Point(point),predicate='intersects');assert len(hit)
            cell=cells[hit[0]];values.append((barycentric(np.array([point]),src[cell])@dst[cell])[0])
        return np.array(values)
    lo=family['sourceSharedFrontageBox'][:2];hi=family['sourceSharedFrontageBox'][2:]
    points=np.array([[x,y] for x in np.linspace(lo[0],hi[0],33) for y in np.linspace(lo[1],hi[1],17)])
    own=evaluate(family,points);shared=evaluate(parent,points)
    report=dict(sampledSharedFrontagePoints=len(points),maximumParentDifferenceSvg=float(np.linalg.norm(own-shared,axis=1).max()),maximumAuthoredWallErrorSvg=float(abs(own[:,1]-180.147).max()),remoteDoorwayMinimumY=195.,regionMaximumY=family['box'][3],sourceTriangles=len(original),mappedTriangles=len(mapped),scope='Sampled local XY contact and raw-height preview; independent continuous seam and baked source proof still required.')
    (out/'local-front-contact-review.json').write_text(json.dumps(report,indent=2));print(report)


if __name__=='__main__':main()

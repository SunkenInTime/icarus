"""Finite connected U-frontage proposal for the original Clove recess complaint."""
import gzip,json
import numpy as np
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
from matplotlib.collections import LineCollection
from build_split_connected_tower import REV
from declare_split_component2_cover_region import grid
from build_split_normalized_wall_families import cut
from authored_region_cells import region_fragments
from tactical_alignment_composite import explicit_warp
from render_split_remaining_corner_families import sections


def declaration():
    raw = np.load(REV/'split-original-scene-connected-source-review-v1/clove-mailroom-recess-full-source.npz')
    proposal = json.loads(gzip.decompress((REV/'split-connected-contour-proposals-v2/component-6.json.gz').read_bytes()))
    spans = [dict(completeSpan=s['completeSpan'],legacyStraightEdgeIndex=s['legacyStraightEdgeIndex'],startSvg=s['authoredEndpoints'][0],endSvg=s['authoredEndpoints'][1]) for s in proposal['spans'] if s['completeSpan'] in [163,185,186,187,188,189]]
    bands = dict(x=[
        dict(spans=[164],source=[161.94726068072814,162.0413420333687],target=162.647),
        dict(spans=[189],source=[169.03956217841812,169.91726703860107],target=169.027),
        dict(spans=[187],source=[196.55847527366893,197.97074700153044],target=197.735),
        dict(spans=[185],source=[201.08708679821876,201.3463783281243],target=200.925)],y=[
        dict(spans=[188],source=[207.7345600322143,210.38973244505496],target=207.792),
        dict(spans=[163,186],source=[222.66083713163482,224.9525549312547],target=223.209)])
    def knots(entries,outer,guard):
        points={outer[0]:outer[0],outer[1]:outer[1],guard[0]:guard[0],guard[1]:guard[1]}
        for entry in entries:
            for value in entry['source']:points[value]=entry['target']
        source=sorted(points);return source,[points[v] for v in source]
    xs,tx=knots(bands['x'],[155.,207.],[158.,204.])
    ys,ty=knots(bands['y'],[190.,232.],[194.,228.])
    family=dict(edge=200188,mappingType='piecewise-affine-region-v1',objects=sorted(np.unique(raw['sourceObjectIds']).tolist()),reviewedSourceFaces=raw['sourceFaceIds'].tolist(),reviewedAuthoredSpans=spans,sourceProfileBands=bands,status='Connected local U proposal; no pack bake.',role='Full finite mailroom frontage, side returns, attached doors, frames and mailboxes use one continuous field. Original height profiles and openings remain.',identityOutsideReason='Finite Y190..232 window is disjoint from component7 Y100..185.5. Shared tower6966 source faces outside each finite region remain unchanged.',sourceRoleReview='Root reviewed full local U source/depth packet; no independent plane snaps.',sourcePacket='split-original-scene-connected-source-review-v1/clove-mailroom-recess-full-source.npz')
    family.update(grid(xs,ys,lambda x,y:[float(np.interp(x,xs,tx)),float(np.interp(y,ys,ty))]));return family


def main(family=None,out=None,original=None):
    family=family or declaration();out=out or REV/'split-mailroom-connected-region-proposal-v1';out.mkdir(exist_ok=True);(out/'region-declaration.json').write_text(json.dumps(family,indent=2))
    if original is None:
        raw=np.load(REV/'split-original-scene-connected-source-review-v1/clove-mailroom-recess-full-source.npz');original=raw['trianglesSvgSourceZ']
    w=json.loads(gzip.decompress((REV/'display-warps-v1/split.display-warp.json.gz').read_bytes()));matrix=np.column_stack((w['projection']['axisU'],w['projection']['axisV']));source=np.array(w['sourceNativeMeters']).reshape(-1,2)@matrix.T+w['projection']['origin'];target=np.array(w['targetAttackSvg']).reshape(-1,2);unwarp=explicit_warp(target,source-target,np.array(w['triangles']).reshape(-1,3));mapped=[]
    for tri in original:
        inside,outside=cut(list(np.column_stack((tri,np.eye(3)))),family['box']);parts=[np.array(p) for p in outside]
        if len(inside)>=3:parts.extend(p for p,_,_ in region_fragments(np.array(inside),family,unwarp))
        for part in parts:mapped.extend(part[[0,j,j+1],:3] for j in range(1,len(part)-1))
    mapped=np.array(mapped);fig,axes=plt.subplots(2,2,figsize=(16,12))
    for ax,z in zip(axes.flat,[8.25,9.75,11.75,14.75]):
        for mesh,color,label in [(original,'#dc2626','Original source'),(mapped,'#16a34a','Connected region proposal')]:
            lines,_=sections(mesh,z);ax.add_collection(LineCollection(lines,colors=color,lw=1.2,label=label))
        for span in family['reviewedAuthoredSpans']:ax.plot(*np.array([span['startSvg'],span['endSvg']]).T,color='#111827',lw=1.2)
        ax.set_xlim(158,205);ax.set_ylim(229,193);ax.set_aspect('equal');ax.grid(alpha=.2);ax.set_title(f'Original absolute Z={z:g}m');ax.legend(fontsize=8)
    fig.suptitle('Mailroom connected U proposal. Mounted frames/mailboxes share their wall field. Original source Z retained.\nFinite region remains disjoint from component7 on shared tower6966. No pack bake.');fig.tight_layout(rect=[0,0,1,.95]);fig.savefig(out/'mailroom-connected-profile-preview.png',dpi=160);plt.close(fig);print(out)


if __name__=='__main__':main()

"""Preserve exact column bevel adjacency for connected corner ownership review."""
import json
from collections import defaultdict
from pathlib import Path
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
from mpl_toolkits.mplot3d.art3d import Poly3DCollection
import numpy as np
from native_compact_wall_profiles import sha
from prepare_ascent_connected_corners import ROOT, OUT


def main():
    declaration_path=OUT/'structural-return-declarations.json'
    declarations=json.loads(declaration_path.read_text())
    raw_path=ROOT/'supplemented-v2/world/ascent/geometry.npz'
    raw=np.load(raw_path);points,faces=raw['points'],raw['faces']
    meta=json.loads(raw_path.with_suffix('.json').read_text())
    affine=np.array(json.loads((ROOT/'tactical-alignment-sides-v1/ascent.json').read_text())['nativeToAttackSvg'])
    cases=[]
    for d in declarations['declarations']:
        if d['completeSpan'] not in [138,194]:continue
        selected=set(d['reviewedSourceFaces']);obj=meta['objects'][d['sourceObject']]
        ids=np.arange(obj['firstFace'],obj['firstFace']+obj['faceCount'])
        edges=defaultdict(set)
        for fid,tri in zip(ids,points[faces[ids]]):
            for i,j in [(0,1),(1,2),(2,0)]:edges[tuple(sorted((tuple(tri[i]),tuple(tri[j]))))].add(int(fid))
        neighbors=set();shared=[]
        for edge,owners in edges.items():
            if owners&selected and owners-selected:
                neighbors|=owners-selected
                shared.append(dict(sourceEdgeNative=[list(x) for x in edge],bodyFaces=sorted(owners&selected),adjacentFaces=sorted(owners-selected)))
        source_ids=sorted(selected|neighbors);xyz=points[faces[source_ids]].copy();svg=xyz.copy();svg[:,:,:2]=svg[:,:,:2]@affine[:,:2].T+affine[:,2]
        records=[]
        for fid,triangle in zip(source_ids,xyz):
            n=np.cross(triangle[1]-triangle[0],triangle[2]-triangle[0]);n/=np.linalg.norm(n)
            role='main-body' if fid in selected else 'vertical-corner-bevel' if abs(n[2])<.01 else 'top-or-bottom-bevel'
            records.append(dict(sourceFace=fid,sourceTriangleNative=triangle.tolist(),sourceNormal=n.tolist(),roleProposal=role,sourceZBounds=[float(triangle[:,2].min()),float(triangle[:,2].max())]))
        fig=plt.figure(figsize=(15,6));top=fig.add_subplot(131);profile=fig.add_subplot(132);view=fig.add_subplot(133,projection='3d')
        o,t=np.array(d['sourceFrame']['origin']),np.array(d['sourceFrame']['tangent'])
        scale=d['targetAlong'][1]/d['sourceAlong'][1]
        for record,tri in zip(records,svg):
            color={'main-body':'#0077b6','vertical-corner-bevel':'#e76f51','top-or-bottom-bevel':'#2a9d8f'}[record['roleProposal']]
            top.plot(*np.vstack((tri[:,:2],tri[:1,:2])).T,color=color,lw=.8,alpha=.6)
            q=np.column_stack(((tri[:,:2]-o)@t*scale,tri[:,2]));profile.fill(q[:,0],q[:,1],color=color,alpha=.2)
            view.add_collection3d(Poly3DCollection(tri[None],facecolor=color,edgecolor=color,alpha=.2,linewidth=.4))
        joins=np.array([j['sourceSvg'] for j in d['joins']]);top.scatter(*joins.T,color='black',s=25,label='Extrapolated plane joins')
        for ax in [top,profile]:ax.grid(alpha=.15)
        top.set_aspect('equal');top.invert_yaxis();top.legend(fontsize=7);top.set_title('Exact shared-edge source triangles')
        profile.set_title('Blue body; orange corner bevel; green top/bottom');profile.set_xlabel('Proposed authored along, SVG');profile.set_ylabel('Original Z, m')
        lo,hi=svg.min((0,1)),svg.max((0,1));view.set_xlim(lo[0],hi[0]);view.set_ylim(lo[1],hi[1]);view.set_zlim(lo[2],hi[2]);view.set_box_aspect(np.maximum(hi-lo,.1));view.view_init(elev=25,azim=-48);view.set_title('Original source assembly, unchanged')
        fig.suptitle(f"Ascent {d['completeSpan']}: exact body-to-bevel adjacency; corner ownership pending")
        fig.tight_layout(rect=[0,0,1,.94]);image=OUT/f"return-{d['completeSpan']}-shared-bevel-review.png";fig.savefig(image,dpi=180,bbox_inches='tight');plt.close(fig)
        cases.append(dict(span=d['completeSpan'],sourceObject=d['sourceObject'],bodyFaces=sorted(selected),immediateAdjacentFaces=sorted(neighbors),sharedEdges=shared,sourceRecords=records,image=str(image),proposedJoinStrategy='Assign each bevel fragment to exactly one incident family and derive the common source anchor from the reviewed body/bevel seam, rather than extrapolated main-plane intersection. Reuse that anchor for both incident mappings. Any collapsed endpoint profile needs original-Z coverage from retained incident profiles. Height-dependent source seam variation remains an explicit clamp/coverage verification requirement.',bakeAllowed=False))
    report=dict(format='icarus-column-bevel-join-review-v1',sourceFileSha256=sha(raw_path),declarationSha256=sha(declaration_path),scriptSha256=sha(Path(__file__)),cases=cases,productionMutation=False)
    (OUT/'column-bevel-join-review.json').write_text(json.dumps(report,indent=2)+'\n')
    print(json.dumps([dict(span=c['span'],bodyFaces=c['bodyFaces'],adjacentFaces=c['immediateAdjacentFaces']) for c in cases],indent=2))


if __name__=='__main__':main()

"""Declare two bounded connected Ascent wall chains for source review only."""
import json
from pathlib import Path
import numpy as np
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
from mpl_toolkits.mplot3d.art3d import Poly3DCollection
from build_split_normalized_wall_families import split
from native_compact_wall_profiles import sha
from prepare_ascent_connected_corners import ROOT,REV,OUT,frame

def clip_along(triangle,lo,hi,o,t):
    data=np.column_stack(((triangle[:,:2]-o)@t,triangle[:,2],np.eye(3)));poly=list(data)
    poly,_=split(poly,0,lo,1);poly,_=split(poly,0,hi,-1)
    return np.array(poly)

def declare():
    inventory=json.loads((OUT/'source-planes.json').read_text());rows={r['span']:r for r in inventory['families']};raw_path=ROOT/'supplemented-v2/world/ascent/geometry.npz';raw=np.load(raw_path);points,faces=raw['points'],raw['faces'];meta=json.loads(raw_path.with_suffix('.json').read_text());affine=np.array(json.loads((ROOT/'tactical-alignment-sides-v1/ascent.json').read_text())['nativeToAttackSvg']);matrix,origin=affine[:,:2],affine[:,2];chains=[]
    for chain_ids,before,after in [([142,143,144],141,145),([212,213,214],211,215)]:
        sequence=[before,*chain_ids,after];joins=[]
        for left,right in zip(sequence,sequence[1:]):
            lp,rp=rows[left]['sourcePlanes'][0],rows[right]['sourcePlanes'][0];xy=np.linalg.solve(np.array([lp['normal'],rp['normal']]),np.array([lp['offset'],rp['offset']]));target=np.array(rows[left]['targetEndpoints'][1]);assert np.array_equal(target,rows[right]['targetEndpoints'][0]);left_ids=np.array(lp['sourceFaces']);right_ids=np.array(rp['sourceFaces']);left_vertices=points[np.unique(faces[left_ids])];right_vertices=points[np.unique(faces[right_ids])];left_xy=left_vertices[:,:2]@matrix.T+origin;right_xy=right_vertices[:,:2]@matrix.T+origin
            joins.append(dict(sourceSvg=xy.tolist(),targetSvg=target.tolist(),betweenSpans=[left,right],derivation='Intersection of the separately identified source wall planes; common anchor used by both family declarations.',minimumLeftSourceVertexDistanceSvg=float(np.linalg.norm(left_xy-xy,axis=1).min()),minimumRightSourceVertexDistanceSvg=float(np.linalg.norm(right_xy-xy,axis=1).min())))
        families=[];all_selected=set();excess=[]
        for i,span_id in enumerate(chain_ids):
            row=rows[span_id];source=np.array([joins[i]['sourceSvg'],joins[i+1]['sourceSvg']]);target=np.array(row['targetEndpoints']);sf,sl=frame(*source);tf,tl=frame(*target);o,t=np.array(sf['origin']),np.array(sf['tangent']);source_ids=sorted(set(fid for group in row['sourcePlanes'] for fid in group['sourceFaces']));source_tri=points[faces[source_ids]].copy();source_tri[:,:,:2]=source_tri[:,:,:2]@matrix.T+origin;selected=[];fragments=[];profiles=[]
            for fid,triangle in zip(source_ids,source_tri):
                along=(triangle[:,:2]-o)@t;clipped=clip_along(triangle,0.,sl,o,t)
                if len(clipped)<3:excess.append(dict(span=span_id,sourceFace=int(fid),decision='Preserve original; entirely outside connected family along interval',alongBounds=[float(along.min()),float(along.max())]));continue
                selected.append(fid);all_selected.add(fid);fragments.append(dict(sourceFace=int(fid),sourceBarycentrics=clipped[:,2:].tolist(),sourceAlongZ=clipped[:,:2].tolist(),targetAlongZ=np.column_stack((clipped[:,0]/sl*tl,clipped[:,1])).tolist()));profiles.append(clipped[:,:2])
                if along.min()<0 or along.max()>sl:excess.append(dict(span=span_id,sourceFace=int(fid),decision='Preserve exact outside fragments; no endpoint clamp beyond source join',alongBounds=[float(along.min()),float(along.max())]))
            families.append(dict(edge=span_id,completeSpan=span_id,legacyStraightEdgeIndex=row['legacyStraightEdgeIndex'],objects=[row['sourceObjectIndex']],sourceObjectPath=row['sourceObjectPath'],sourceFrame=sf,targetFrame=tf,sourceAlong=[0.,sl],targetAlong=[0.,tl],reviewedSourceFaces=selected,originalHeightFragments=fragments,sharedSourceJoins=source.tolist(),sharedAuthoredJoins=target.tolist(),sourceClipPolicy='Clip to these shared source joins. Retain all outside source fragments unchanged. Do not collapse a distinct frontage merely because it is parallel.',heightPolicy='Preserve each original source vertex Z through exact source barycentrics. Do not fill gaps, merge height sheets or extrude an upper/lower envelope.',alphaPolicy='Retain original source face identity, UV and material when later compiled. This proposal does not classify opacity.',status='Proposal only; attached caps/relief and external frontier closure need review before baking.'))
        # Record all nearby unassigned facets, not names-based automatic ownership.
        facets=[]
        for obj in sorted({r['objects'][0] for r in families}):
            ob=meta['objects'][obj];ids=np.arange(ob['firstFace'],ob['firstFace']+ob['faceCount']);triangles=points[faces[ids]].copy();triangles[:,:,:2]=triangles[:,:,:2]@matrix.T+origin
            for j,join in enumerate(joins):
                xy=np.array(join['sourceSvg']);near=np.all(triangles[:,:,:2].max(1)>=xy-1.,axis=1)&np.all(triangles[:,:,:2].min(1)<=xy+1.,axis=1)
                for fid,triangle in zip(ids[near],triangles[near]):
                    if int(fid) not in all_selected:facets.append(dict(sourceFace=int(fid),object=obj,nearJoin=j,sourceSvgZ=triangle.tolist(),decision='Unassigned source facet; preserve unchanged until its structural role is reviewed.'))
        chain=dict(spans=chain_ids,sourceJoins=joins,families=families,externalFrontiers=[dict(span=before,join=joins[0],status='Unchanged adjacent wall requires paired closure verification'),dict(span=after,join=joins[-1],status='Unchanged adjacent wall requires paired closure verification')],outsideSourceFragments=excess,unassignedCornerFacets=facets)
        chains.append(chain)
        fig=plt.figure(figsize=(17,11));top=fig.add_subplot(221);view=fig.add_subplot(222,projection='3d');colors=['#0077b6','#e76f51','#2a9d8f']
        for f,color in zip(families,colors):
            ids=np.array(f['reviewedSourceFaces']);xyz=points[faces[ids]];svg=xyz.copy();svg[:,:,:2]=svg[:,:,:2]@matrix.T+origin
            for triangle in svg:top.plot(*np.vstack((triangle[:,:2],triangle[:1,:2])).T,color=color,alpha=.15,lw=.4)
            target=np.array(f['sharedAuthoredJoins']);top.plot(*target.T,color=color,lw=2,label=f"SVG {f['edge']}");view.add_collection3d(Poly3DCollection(xyz,facecolor=color,edgecolor=color,alpha=.12,linewidth=.1))
        all_xyz=points[faces[sorted(all_selected)]];lo=all_xyz.min((0,1));hi=all_xyz.max((0,1));view.set_xlim(lo[0],hi[0]);view.set_ylim(lo[1],hi[1]);view.set_zlim(lo[2],hi[2]);view.set_box_aspect(np.maximum(hi-lo,.1));view.view_init(elev=26,azim=-48);view.set_title('Actual original source planes; gaps remain open');view.set_xlabel('Native X, m');view.set_ylabel('Native Y, m');view.set_zlabel('Original source Z, m');top.scatter(*np.array([j['sourceSvg'] for j in joins]).T,c='black',s=15,label='Shared source joins');top.invert_yaxis();top.set_aspect('equal');top.legend(fontsize=8);top.set_title('Source planes and authored connected chain')
        for k,f in enumerate(families):
            ax=fig.add_subplot(2,3,4+k)
            for fragment in f['originalHeightFragments']:
                q=np.array(fragment['targetAlongZ']);ax.fill(q[:,0],q[:,1],color=colors[k],alpha=.18);ax.plot(*np.vstack((q,q[:1])).T,color=colors[k],alpha=.3,lw=.35)
            ax.set_xlabel('Proposed along, SVG');ax.set_ylabel('Original Z, m');ax.set_title(f"Span {f['edge']}: {len(f['reviewedSourceFaces'])} faces");ax.grid(alpha=.15)
        fig.suptitle(f"Ascent connected proposal {chain_ids}; no geometry bake. Outside fragments and caps remain explicit.");fig.tight_layout(rect=[0,0,1,.96]);fig.savefig(OUT/f'connected-{chain_ids[1]}-source-review.png',dpi=180);plt.close(fig)
    report=dict(format='icarus-connected-source-wall-proposal-v1',map='ascent',sourceInventorySha256=sha(OUT/'source-planes.json'),sourceGeometrySha256=inventory['sourceGeometrySha256'],sourceFileSha256=sha(raw_path),displayWarpSha256=inventory['warpSha256'],scriptSha256=sha(Path(__file__)),chains=chains,productionMutation=False,acceptance='Source review proposal only. No corner/height/visibility equivalence or application acceptance is claimed.')
    (OUT/'connected-proposals.json').write_text(json.dumps(report,indent=2)+'\n');print(json.dumps([dict(spans=c['spans'],sourceJoins=c['sourceJoins'],faceCounts={f['edge']:len(f['reviewedSourceFaces']) for f in c['families']},outsideFragments=len(c['outsideSourceFragments']),unassignedFacets=len(c['unassignedCornerFacets'])) for c in chains],indent=2))
if __name__=='__main__':declare()

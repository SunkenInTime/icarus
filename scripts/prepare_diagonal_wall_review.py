"""Two source-bound diagonal wall proposals. No geometry mutation."""
import gzip
import hashlib
import json
from pathlib import Path
import numpy as np
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
from matplotlib.collections import LineCollection
from mpl_toolkits.mplot3d.art3d import Poly3DCollection
from render_competing_floor_assemblies import clip_mesh_xy
from render_split_remaining_corner_families import sections
from tactical_alignment_audit import pack
from tactical_alignment_composite import explicit_warp

ROOT=Path('E:/IcarusWorldAudit/2026-09-06');REV=ROOT/'tactical-visibility-revision'

def frame(start,end):
    start,end=np.array(start),np.array(end);u=end-start;length=float(np.linalg.norm(u));u/=length
    return dict(origin=start.tolist(),tangent=u.tolist(),normal=[-float(u[1]),float(u[0])]),length

def main():
    out=REV/'diagonal-wall-source-review-v1';out.mkdir(exist_ok=True)
    proposals=[]
    for name,legacy,obj,mainfaces in [('split',84,5928,[1894119,1894120]),('ascent',159,8033,[2963443,2963444])]:
        coverage_path=REV/f'all-map-wall-span-coverage-v1/{name}/attack.coverage.json.gz';coverage=json.loads(gzip.decompress(coverage_path.read_bytes()));span=next(s for s in coverage['spans'] if s['legacyStraightEdgeIndex']==legacy);rows=[coverage['samples'][i] for i in span['sampleRows']]
        rawpath=ROOT/f'supplemented-v2/world/{name}/geometry.npz';raw=np.load(rawpath);points,faces=raw['points'],raw['faces'];meta=json.loads(rawpath.with_suffix('.json').read_text());instance=meta['objects'][obj]
        affine=np.array(json.loads((ROOT/f'tactical-alignment-sides-v1/{name}.json').read_text())['nativeToAttackSvg']);matrix,origin=affine[:,:2],affine[:,2]
        exact=points[faces[mainfaces]].copy();exact[:,:,:2]=exact[:,:,:2]@matrix.T+origin
        first=exact[0];bottom=first[np.argsort(first[:,2])[:2],:2];target_delta=np.array(span['endSvg'])-span['startSvg'];bottom=bottom[np.argsort(bottom@target_delta)]
        source_frame,source_length=frame(bottom[0],bottom[1]);target_frame,target_length=frame(span['startSvg'],span['endSvg'])
        ids=np.arange(instance['firstFace'],instance['firstFace']+instance['faceCount']);mesh=points[faces[ids]].copy();mesh[:,:,:2]=mesh[:,:,:2]@matrix.T+origin
        u=np.array(source_frame['tangent']);n=np.array(source_frame['normal']);sorigin=np.array(source_frame['origin']);local=mesh.copy();local[:,:,0]=(mesh[:,:,:2]-sorigin)@u;local[:,:,1]=(mesh[:,:,:2]-sorigin)@n
        roi=(local[:,:,0].max(1)>=-1)&(local[:,:,0].min(1)<=source_length+1)&(local[:,:,1].max(1)>=-1.5)&(local[:,:,1].min(1)<=1.5)
        near=(abs(local[:,:,1]).max(1)<.05)&(local[:,:,0].max(1)>=0)&(local[:,:,0].min(1)<=source_length)
        primary_ids=ids[near];reported_faces=sorted(set(s['originalSourceFace'] for s in rows if s['status']=='contact'))
        proposal=dict(map=name,legacyStraightEdge=legacy,completeSpan=span['span'],authoredStart=span['startSvg'],authoredEnd=span['endSvg'],sourceFrame=source_frame,targetFrame=target_frame,sourceAlong=[0,source_length],targetAlong=[0,target_length],sourceObjectIndex=obj,sourceObject=instance,primaryPlaneSourceFaces=primary_ids.tolist(),originalFirstContactFaces=reported_faces,nearbyReviewSourceFaces=ids[roi].tolist(),mainFaceVerticesNative=points[faces[mainfaces]].tolist(),mainFaceIds=mainfaces,sourceGeometrySha256=meta['geometrySha256'],coverageSha256=hashlib.sha256(coverage_path.read_bytes()).hexdigest(),artSha256=coverage['artSha256'],standingGapRangeSvg=[min(s['inwardGapSvg'] for s in rows),max(s['inwardGapSvg'] for s in rows)],status='source-role-review-proposal; no normalization or corner acceptance',evidenceLimit='Primary coplanar candidates are selected geometrically; nearby triangles and endpoint caps remain for explicit review. Front profile uses original source Z, while 2D sections use provisional relative control geometry.')
        neighbors=[s for s in coverage['spans'] if s['subpath']==span['subpath'] and s['elementIndex']==span['elementIndex'] and (np.linalg.norm(np.array(s['startSvg'])-span['endSvg'])<1e-7 or np.linalg.norm(np.array(s['endSvg'])-span['startSvg'])<1e-7)]
        proposal['adjacentAuthoredSpans']=[{k:s[k] for k in ['span','legacyStraightEdgeIndex','startSvg','endSvg','segmentType']} for s in neighbors]
        (out/f'{name}-{legacy}.json').write_text(json.dumps(proposal,indent=2));proposals.append(proposal)
        fig=plt.figure(figsize=(17,10));ax=fig.add_subplot(221,projection='3d')
        minxy=np.minimum(span['startSvg'],span['endSvg'])-3;maxxy=np.maximum(span['startSvg'],span['endSvg'])+3
        clipped=clip_mesh_xy(mesh[roi],minxy,maxxy)
        def display_local(triangles):
            result=triangles.copy();result[:,:,0]=(triangles[:,:,:2]-sorigin)@u;result[:,:,1]=(triangles[:,:,:2]-sorigin)@n
            return result
        local_clipped=display_local(clipped);local_exact=display_local(exact)
        ax.add_collection3d(Poly3DCollection(local_clipped,facecolors='#94a3b8',edgecolors='#475569',alpha=.3,linewidths=.15));ax.add_collection3d(Poly3DCollection(local_exact,facecolors='#0ea5e9',edgecolors='#075985',alpha=.9,linewidths=.5));lo,hi=local_clipped.reshape(-1,3).min(0),local_clipped.reshape(-1,3).max(0);ax.set_xlim(lo[0],hi[0]);ax.set_ylim(lo[1],hi[1]);ax.set_zlim(lo[2],hi[2]);ax.set_box_aspect(np.maximum((hi-lo)*[1,1,np.linalg.norm(matrix[:,0])],.1));ax.view_init(22,-65);ax.set_title('Original source; diagonal primary plane blue');ax.set_xlabel('Along source wall, SVG');ax.set_ylabel('Normal depth, SVG');ax.set_zlabel('Original source Z, m')
        ax=fig.add_subplot(222)
        for i in np.flatnonzero(near):
            profile=local[i][:,[0,2]]
            ax.fill(*profile.T,color='#0ea5e9',alpha=.35);ax.plot(*np.vstack((profile,profile[0])).T,linewidth=.4,color='#075985')
        ax.set_xlabel('Along source wall, SVG units');ax.set_ylabel('Original source Z, m');ax.set_title('Source diagonal-plane height profile; no extrusion');ax.grid(alpha=.2)
        control=REV/f'global-ground-complete-v2/{name}';_,arrays=pack(control/f'{name}.height.bin.gz');full=np.load(control/'correspondence.npz')['sourceFaces'];original=np.load(REV/f'full-height-input-v1/{name}/source-correspondence.npz')['sourceFaces'];object_control=np.flatnonzero((original[full]>=instance['firstFace'])&(original[full]<instance['firstFace']+instance['faceCount']));tri=arrays['vertices'][arrays['faces'][object_control]].copy();tri[:,:,:2]=tri[:,:,:2]@matrix.T+origin
        w=json.loads(gzip.decompress((REV/f'display-warps-v1/{name}.display-warp.json.gz').read_bytes()));before=np.array(w['sourceNativeMeters']).reshape(-1,2)@matrix.T+origin;target=np.array(w['targetAttackSvg']).reshape(-1,2);warp=explicit_warp(before,target-before,np.array(w['triangles']).reshape(-1,3))
        for slot,z in enumerate([.75,1.75]):
            ax=fig.add_subplot(2,2,slot+3);ss,_=sections(tri,z);paths=[]
            for line in ss:
                samples=np.linspace(line[0],line[1],max(2,int(np.linalg.norm(line[1]-line[0])/.15)+1));mapped=warp.apply(samples);paths.extend(np.stack((mapped[:-1],mapped[1:]),axis=1))
            ax.add_collection(LineCollection(paths,colors='#0284c7',linewidths=1))
            for s in [span]+neighbors:
                line=np.array([s['startSvg'],s['endSvg']]);ax.plot(*line.T,color='#ea580c',linewidth=2);ax.text(*line.mean(0),str(s['legacyStraightEdgeIndex']),color='#c2410c')
            ax.set_xlim(minxy[0],maxxy[0]);ax.set_ylim(maxxy[1],minxy[1]);ax.set_aspect('equal');ax.grid(alpha=.2);ax.set_title(f'Control section {z}m with display W; exact art orange')
        fig.suptitle(f'{name.title()} diagonal wall {legacy}, exact instance {obj}. Original profile and neighboring corners remain separate.');fig.tight_layout();fig.savefig(out/f'{name}-{legacy}.png',dpi=160);plt.close(fig)
    (out/'manifest.json').write_text(json.dumps(proposals,indent=2));print(out)

if __name__=='__main__':main()

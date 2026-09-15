"""Bounded original-source wall review packets; no normalization or acceptance."""
import argparse
from collections import Counter
import gzip
import json
from pathlib import Path
import numpy as np
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
from matplotlib.collections import PolyCollection
from mpl_toolkits.mplot3d.art3d import Poly3DCollection
from audit_all_map_wall_span_coverage import ROOT,REV,sha,authored_spans
from native_reference_cast import NativeReferenceModel
from tactical_alignment_composite import explicit_warp

CHOICES={'ascent':[143,213,92],'icebox':[115,98,147]}

def main(name):
    output=REV/f'{name}-wall-family-review-v1';output.mkdir(exist_ok=False)
    coverage_path=REV/f'all-map-wall-span-coverage-v1/{name}/attack.coverage.json.gz'
    coverage=json.loads(gzip.decompress(coverage_path.read_bytes()))
    manifest=json.loads((ROOT/'completeness/combined-manifest-release-inputs-v2.json').read_text())
    meta_path=Path(next(r for r in manifest if r['map']==name)['combinedWorldFolder'])/'geometry.json'
    meta=json.loads(meta_path.read_text());raw=np.load(meta_path.with_suffix('.npz'));points,faces=raw['points'],raw['faces']
    starts=np.array([o['firstFace'] for o in meta['objects']])
    control_path=REV/f'global-ground-complete-v2/{name}/{name}.height.bin.gz'
    source=NativeReferenceModel(control_path,REV/'native-tactical-rays-build/Release/tactical_reference_cast.dll')
    c2f=np.load(control_path.parent/'correspondence.npz')['sourceFaces']
    f2o=np.load(REV/f'full-height-input-v1/{name}/source-correspondence.npz')['sourceFaces']
    warp_path=REV/f'display-warps-v1/{name}.display-warp.json.gz';warp=json.loads(gzip.decompress(warp_path.read_bytes()))
    native=np.array(warp['sourceNativeMeters']).reshape(-1,2);target=np.array(warp['targetAttackSvg']).reshape(-1,2);indices=np.array(warp['triangles']).reshape(-1,3)
    matrix=np.column_stack((warp['projection']['axisU'],warp['projection']['axisV']));origin=np.array(warp['projection']['origin']);projected=native@matrix.T+origin
    forward=explicit_warp(projected,target-projected,indices);backward=explicit_warp(target,projected-target,indices)
    def svg(xy):return forward.apply(np.asarray(xy)@matrix.T+origin)
    artwork=Path(f'assets/maps/{name}_map.svg');all_spans=authored_spans(artwork);summaries=[]
    for span_id in CHOICES[name]:
        print(name,'span',span_id,flush=True)
        span=coverage['spans'][span_id];rows=[coverage['samples'][i] for i in span['sampleRows']]
        standing=[r for r in rows if r.get('relativeEyeHeightMeters')==1.75 and r['status']=='contact' and r.get('probeStartInsideReceiver')]
        primary=Counter(r['sourceObjectIndex'] for r in standing).most_common(1)[0][0]
        primary_rows=[r for r in standing if r['sourceObjectIndex']==primary]
        pids=np.unique([r['originalSourceFace'] for r in primary_rows]);ptris=points[faces[pids]]
        normals=np.cross(ptris[:,1]-ptris[:,0],ptris[:,2]-ptris[:,0]);normals/=np.linalg.norm(normals,axis=1)[:,None]
        ref=normals[0,:2];ref/=np.linalg.norm(ref);normals[np.einsum('ij,j->i',normals[:,:2],ref)<0]*=-1
        normal=np.median(normals[:,:2],axis=0);normal/=np.linalg.norm(normal);axis=np.array([-normal[1],normal[0]])
        center=np.median(np.array([r['hitControlXYZ'][:2] for r in primary_rows]),axis=0)
        hits=np.array([r['hitControlXYZ'][:2] for r in primary_rows]);along=(hits-center)@axis;umin,umax=along.min(),along.max()
        plane_offset=float(np.median((ptris.reshape(-1,3)[:,:2]-center)@normal))
        secondary=[];touched=set(pids.tolist());objects={primary}
        for row in rows:
            if 'probeNativeXY' not in row:continue
            a,b=np.array(row['probeNativeXY']);height=row['relativeEyeHeightMeters'];o=np.r_[a,height];t=np.r_[b,height];minimum=1e-5;contacts=[]
            for depth in range(8):
                hit=source.cast(o,t,min_distance=minimum)
                if hit is None:break
                control=int(hit['face']);full=int(c2f[control]);original=int(f2o[full]);obj=int(np.searchsorted(starts,original,side='right')-1)
                contact=dict(depth=depth,controlFace=control,fullPackFace=full,originalSourceFace=original,sourceObjectIndex=obj,
                             pointControl=hit['point'],pointSvg=svg(hit['point'][:2]).tolist(),distanceMeters=hit['distanceMeters'],masked=hit['masked'])
                contacts.append(contact);touched.add(original);objects.add(obj);minimum=hit['distanceMeters']+1e-6
            secondary.append(dict(alongSvg=row['alongSvg'],relativeEyeHeightMeters=height,contacts=contacts,truncated=len(contacts)==8))
        # Retain the complete primary instance and independently identified local
        # geometry. Exact IDs bind candidates; no object-wide wall mutation implied.
        obj=meta['objects'][primary];ids=np.arange(obj['firstFace'],obj['firstFace']+obj['faceCount']);triangles=points[faces[ids]]
        local_u=(triangles[:,:,:2]-center)@axis;local_v=(triangles[:,:,:2]-center)@normal
        cross=np.cross(triangles[:,1]-triangles[:,0],triangles[:,2]-triangles[:,0]);size=np.linalg.norm(cross,axis=1);unit=cross/np.maximum(size[:,None],1e-30)
        aligned=(np.abs(unit[:,:2]@normal)>.99999)&(np.abs(unit[:,2])<1e-4)
        near=np.max(np.abs(local_v-plane_offset),axis=1)<.005
        bounded=(local_u.max(1)>=umin-.02)&(local_u.min(1)<=umax+.02)
        family_ids=ids[aligned&near&bounded];family_triangles=points[faces[family_ids]]
        angles=[]
        for row in primary_rows:
            d=np.diff(np.array(row['probeNativeXY']),axis=0)[0];d/=np.linalg.norm(d);angles.append(float(np.rad2deg(np.arccos(np.clip(abs(d@normal),0,1)))))
        # Local context from every touched source instance, clipped only for view.
        context=[];context_ids=[];context_obj=[]
        for object_id in sorted(objects):
            ob=meta['objects'][object_id];fi=np.arange(ob['firstFace'],ob['firstFace']+ob['faceCount']);tr=points[faces[fi]]
            u=(tr[:,:,:2]-center)@axis;v=(tr[:,:,:2]-center)@normal
            keep=(u.max(1)>=umin-1)&(u.min(1)<=umax+1)&(v.max(1)>=-2)&(v.min(1)<=2)
            context.extend(tr[keep]);context_ids.extend(fi[keep].tolist());context_obj.extend([object_id]*int(keep.sum()))
        context=np.array(context);context_ids=np.array(context_ids);context_obj=np.array(context_obj)
        height_stats={}
        for height in (.75,1.75,2.75):
            rr=[r for r in rows if r.get('relativeEyeHeightMeters')==height]
            height_stats[str(height)]=dict(samples=len(rr),contacts=sum(r['status']=='contact' for r in rr),
                primaryContacts=sum(r.get('sourceObjectIndex')==primary for r in rr),
                otherInstances=dict(Counter(str(r['sourceObjectIndex']) for r in rr if 'sourceObjectIndex' in r and r['sourceObjectIndex']!=primary)),
                unresolved=[r for r in rr if r['status']!='contact' or not r.get('probeStartInsideReceiver')])
        record=dict(map=name,span=span,primaryInstanceIndex=primary,primaryInstance=obj,
            firstHitSourceFaceIds=pids.tolist(),candidateOriginalSourceFaceIds=family_ids.tolist(),
            candidateFullPackFaceIds=np.flatnonzero(np.isin(f2o,family_ids)).tolist(),
            candidateControlFaceIds=np.flatnonzero(np.isin(f2o[c2f],family_ids)).tolist(),
            sourcePlane=dict(originXY=center.tolist(),normalXY=normal.tolist(),axisXY=axis.tolist(),normalOffsetMeters=plane_offset,alongBoundsMeters=[float(umin),float(umax)],
                             toleranceMeters=.005,maximumProbeNormalAngleDegrees=max(angles)),
            controlHeightCoverage=height_stats,originalSamples=rows,secondaryContacts=secondary,
            secondaryInstanceCounts=dict(Counter(str(c['sourceObjectIndex']) for r in secondary for c in r['contacts'][1:])),
            sourceObjects=[dict(sourceObjectIndex=i,**meta['objects'][i]) for i in sorted(objects)],
            originalSourceFaces=[dict(face=int(i),instance=int(np.searchsorted(starts,i,side='right')-1),vertices=points[faces[i]].tolist()) for i in sorted(touched|set(family_ids.tolist()))],
            medianStandingGapSvg=float(np.median([r['inwardGapSvg'] for r in primary_rows])),
            status='candidate-source-review-no-geometry-change',
            limitations=['Control eye heights are relative to frozen ground policy, not every gameplay floor.','Secondary casts advance one micrometer after each contact, so coincident backing faces require explicit source geometry review.','Candidate plane face IDs include only the primary instance within the sampled along-wall interval; corner and adjacent instance ownership is not inferred.','Five-millimeter candidate selection tolerance is inventory only, not normalization authority.'])
        (output/f'span-{span_id}.json').write_text(json.dumps(record,indent=2)+'\n')
        np.savez_compressed(output/f'span-{span_id}-source-context.npz',vertices=context,sourceFaces=context_ids,sourceObjects=context_obj,candidateFaces=family_ids)
        fig=plt.figure(figsize=(17,12));fig.suptitle(f'{name.title()} span {span_id} | source instance {primary} | standing gap {record["medianStandingGapSvg"]:.3f} SVG',fontsize=17)
        ax=fig.add_subplot(221);line=np.array([span['startSvg'],span['endSvg']]);lo=line.min(0)-8;hi=line.max(0)+8
        for sr,seg in all_spans:
            q=np.array([[seg.point(t).real,seg.point(t).imag] for t in np.linspace(0,1,20)])
            if np.all(q.max(0)>=lo) and np.all(q.min(0)<=hi):ax.plot(q[:,0],q[:,1],color='#9d743e',lw=1)
        ax.plot(line[:,0],line[:,1],color='red',lw=3,label='Authored SVG span')
        for h,col in [(.75,'#138f89'),(1.75,'#2363d4'),(2.75,'#aa44bb')]:
            rr=[r for r in rows if r.get('relativeEyeHeightMeters')==h and 'hitSvg' in r];xy=np.array([r['hitSvg'] for r in rr]);ax.scatter(xy[:,0],xy[:,1],s=8,c=col,label=f'Control eye {h}m')
        ax.set(xlim=(lo[0],hi[0]),ylim=(hi[1],lo[1]),title='SVG outline and control first contacts');ax.set_aspect('equal');ax.legend(fontsize=8)
        ax=fig.add_subplot(222)
        uvz=np.stack([(context[:,:,:2]-center)@axis,context[:,:,2]],axis=-1)
        ax.add_collection(PolyCollection(uvz,facecolors='#cccccc',edgecolors='#aaaaaa',linewidths=.15,alpha=.25))
        family_uvz=np.stack([(family_triangles[:,:,:2]-center)@axis,family_triangles[:,:,2]],axis=-1)
        ax.add_collection(PolyCollection(family_uvz,facecolors='#2c6acc',edgecolors='#10418c',linewidths=.4,alpha=.8));ax.autoscale_view();ax.set(xlim=(umin-1,umax+1),xlabel='Along source wall (m)',ylabel='Original world Z (m)',title='Original source elevation; candidate plane in blue')
        ax=fig.add_subplot(223,projection='3d');local=np.stack([(context[:,:,:2]-center)@axis,(context[:,:,:2]-center)@normal,context[:,:,2]],axis=-1)
        ax.add_collection3d(Poly3DCollection(local,facecolors='#b7b7b7',edgecolors='#777777',linewidths=.12,alpha=.12))
        ft=np.stack([(family_triangles[:,:,:2]-center)@axis,(family_triangles[:,:,:2]-center)@normal,family_triangles[:,:,2]],axis=-1)
        ax.add_collection3d(Poly3DCollection(ft,facecolors='#2476cf',edgecolors='#184780',linewidths=.3,alpha=.8));zlo,zhi=np.quantile(context[:,:,2],[.01,.99]);ax.set(xlim=(umin-1,umax+1),ylim=(-2,2),zlim=(zlo,zhi),xlabel='Along wall (m)',ylabel='Across wall (m)',zlabel='World Z (m)',title='Original 3D source geometry, no normalization');ax.view_init(23,-62);ax.set_box_aspect((max(umax-umin,1),4,max(zhi-zlo,1)))
        ax=fig.add_subplot(224)
        for h,col in [(.75,'#138f89'),(1.75,'#2363d4'),(2.75,'#aa44bb')]:
            rr=[r for r in rows if r.get('relativeEyeHeightMeters')==h and 'inwardGapSvg' in r];ax.plot([r['alongSvg'] for r in rr],[r['inwardGapSvg'] for r in rr],'.-',ms=3,lw=.6,color=col,label=f'{h}m')
        ax.axhline(0,c='red',lw=1);ax.set(xlabel='Along authored SVG span',ylabel='Inward contact offset (SVG units)',title='Height coverage and explicit corner deviations');ax.legend()
        fig.tight_layout(rect=(0,0,1,.96));fig.savefig(output/f'span-{span_id}-review.png',dpi=160);plt.close(fig)
        summaries.append({k:record[k] for k in ('map','primaryInstanceIndex','medianStandingGapSvg','sourcePlane','controlHeightCoverage','secondaryInstanceCounts')})
    report=dict(map=name,coverageSha256=sha(coverage_path),sourceMetadataSha256=sha(meta_path),sourceGeometrySha256=meta['geometrySha256'],controlPackSha256=sha(control_path),displayWarpSha256=sha(warp_path),artSha256=sha(artwork),scriptSha256=sha(Path(__file__)),candidates=summaries)
    (output/'summary.json').write_text(json.dumps(report,indent=2)+'\n');print('complete',output,flush=True)

if __name__=='__main__':
    parser=argparse.ArgumentParser();parser.add_argument('map',choices=CHOICES);main(parser.parse_args().map)

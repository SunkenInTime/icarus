"""Check finite pipe proposal contacts and preservation before a pack bake."""
import gzip
import json
from pathlib import Path

import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
import numpy as np

from native_compact_wall_profiles import sha
from tactical_alignment_composite import explicit_warp
from verify_region_contact import verify_contact, segment_cells, interval_values
from render_split_remaining_corner_families import sections

REV=Path('E:/IcarusWorldAudit/2026-09-06/tactical-visibility-revision')


def mapper(f):
    source=np.asarray(f['sourceVerticesSvg']);target=np.asarray(f['targetVerticesSvg'])
    return explicit_warp(source,target-source,np.asarray(f['triangles']))


def main():
    folder=REV/'split-pipe130-profile-region-proposal-v5'
    path=folder/'region-declaration.json';new=json.loads(path.read_text())
    old_path=REV/'split-wall-family-normalized-candidate-v26/bindings.json'
    old=next(f for f in json.loads(old_path.read_text())['families'] if f['edge']==new['edge'])
    field=mapper(new);old_field=mapper(old)
    proposal=new['pipe130ProfileProposal'];post,join=proposal['sourceAlong'];low,high=proposal['sourceNormalBand']
    corners=np.array(proposal['target130'])
    contact=verify_contact(new,[[post,low],[join,low]],new,[[post,high],[join,high]],corners)
    # Boundary intervals use all cuts of both maps. Every endpoint agrees;
    # each interval is affine, so no hidden intervening seam can be missed.
    x0,y0,x1,y1=proposal['sourceBox'];box=np.array([[x0,y0],[x1,y0],[x1,y1],[x0,y1]])
    boundary=[]
    for a,b in zip(box,np.roll(box,-1,axis=0)):
        first=segment_cells(old,[a,b]);second=segment_cells(new,[a,b]);times=np.unique(np.r_[first[-1],second[-1]])
        errors=[]
        for start,end in zip(times[:-1],times[1:]):
            left=interval_values(first,start,end);right=interval_values(second,start,end)
            errors.append(float(np.linalg.norm(left[:,None]-right[None,:],axis=-1).max()))
        error=max(errors,default=0);assert error<1e-7,error
        boundary.append(dict(sourceSegment=[a.tolist(),b.tolist()],intervals=len(times)-1,maximumChangedBoundarySvg=error))
    # The entire doorway/header to the left of the first jamb depth plane is
    # outside the changed region. Check all new source-cell vertices there,
    # plus every original cell/vertex subdivision on that side.
    source=np.asarray(new['sourceVerticesSvg']);target=np.asarray(new['targetVerticesSvg']);cells=np.asarray(new['triangles'])
    untouched=(source[:,0]<=x0)|(source[:,0]>=x1)|(source[:,1]<=y0)|(source[:,1]>=y1)
    errors=np.linalg.norm(old_field.apply(source[untouched])-target[untouched],axis=1)
    assert errors.max()<1e-7,errors.max()
    header_left=(source[:,0]<=x0)&(source[:,0]>=220)&(source[:,1]>=210)&(source[:,1]<=224)
    header_error=float(np.linalg.norm(old_field.apply(source[header_left])-target[header_left],axis=1).max(initial=0))
    assert header_error<1e-7
    # Exact source-height section segments are split at every new region edge.
    # Their affine pieces retain the source Z; normal projection is checked
    # without relying on a fixed number of points along each segment.
    packet_path=REV/'split-clove-pipe7479-review-v3/source-context.npz';packet=np.load(packet_path)
    warp=json.loads(gzip.decompress((REV/'display-warps-v1/split.display-warp.json.gz').read_bytes()))
    matrix=np.column_stack([warp['projection']['axisU'],warp['projection']['axisV']]);origin=np.array(warp['projection']['origin'])
    chosen=np.isin(packet['sourceObjectIds'],[7478,7479,7480,7481,7633,7634]);tri=packet['triangles'][chosen].copy()
    tri[:,:,:2]=tri[:,:,:2]@matrix.T+origin
    section_rows=[];plotted=[]
    heights=[6.49506950378418,6.59,6.781631480113873,8.263667525596553,9.42,10.83,11.5,12.18506908416748]
    tangent=(corners[1]-corners[0])/np.linalg.norm(corners[1]-corners[0]);normal=np.array([-tangent[1],tangent[0]])
    for z in heights:
        lines,ids=sections(tri,z);parts=[];proof_parts=0;maximum=0.
        for line in lines:
            if np.array_equal(line[0],line[1]):
                parts.append(np.repeat(field.apply(line[:1]),2,axis=0));continue
            data=segment_cells(new,line)
            for start,end in zip(data[-1][:-1],data[-1][1:]):
                # Query the same independent interval evaluator used in the
                # source-contact proof, including coincident-cell agreement.
                values=interval_values(data,start,end)
                assert np.linalg.norm(values-values[:1],axis=-1).max()<1e-7
                part=values[0];parts.append(part)
                endpoints=line[0]+np.array([start,end])[:,None]*(line[1]-line[0])
                if (endpoints[:,0]>=post-1e-9).all() and (endpoints[:,0]<=join+1e-9).all() and (endpoints[:,1]>=low-1e-9).all() and (endpoints[:,1]<=high+1e-9).all():
                    error=float(abs((part-corners[0])@normal).max());maximum=max(maximum,error);proof_parts+=1
        assert maximum<1e-7,maximum
        parts=np.asarray(parts).reshape(-1,2,2)
        section_rows.append(dict(originalHeightMeters=z,sourceSections=len(lines),mappedAffineParts=len(parts),
            certified130Parts=proof_parts,maximum130NormalErrorSvg=maximum))
        plotted.append(parts)
    fig,axes=plt.subplots(2,4,figsize=(17,9))
    for ax,z,parts in zip(axes.flat,heights,plotted):
        ax.plot(*corners.T,color='black',lw=4,alpha=.35)
        ax.plot([238.139,240.797],[216.298,216.298],color='black',lw=4,alpha=.35)
        for p in parts:ax.plot(*p.T,color='#ea580c',lw=1.2)
        ax.set_title(f'Original height {z:.6f}m');ax.set_xlim(235,242);ax.set_ylim(220,211);ax.set_aspect('equal');ax.grid(alpha=.15)
    fig.suptitle('Exact affine source sections after the pipe/profile proposal\nOrange retains source height extent and port/elbow variation. Gray is authored130/131. No full-height extrusion.')
    fig.tight_layout();fig.savefig(folder/'exact-height-sections.png',dpi=170);plt.close(fig)
    result=dict(passed=True,declarationSha256=sha(path),originalBindingsSha256=sha(old_path),sourcePacketSha256=sha(packet_path),
        verifierSha256=sha(Path(__file__)),profileContact=contact,finiteFieldBoundary=boundary,
        unchangedOutsideVertexCount=int(untouched.sum()),maximumOutsideTargetErrorSvg=float(errors.max()),
        unchangedLeftDoorHeaderVertexCount=int(header_left.sum()),maximumLeftDoorHeaderErrorSvg=header_error,
        originalHeightSectionChecks=section_rows,
        limitations=['Declared-field proof only. Full source fragment partition, material preservation and actual app replay await a candidate bake.',
                     'Source Z is never edited by the declaration; no new opening or solid-height classification is inferred.'])
    (folder/'independent-contact-height-review.json').write_text(json.dumps(result,indent=2)+'\n')
    print(json.dumps(result,indent=2))


if __name__=='__main__':main()

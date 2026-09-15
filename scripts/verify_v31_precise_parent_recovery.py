"""Verify the complete failed200140 parent after exact clipping-weight reuse."""
import gzip
import json
from pathlib import Path
import numpy as np
from native_compact_wall_profiles import sha
from tactical_alignment_composite import explicit_warp
from finite_region_cells import region_fragments
from native_region_source import native_source_rows
from authored_wall_profile_cells import inverse_in_cell
from verify_normalized_wall_profiles import verify_source_partition,reconstruct_source_points
from verify_region_mapping import verify_region_fragments

REV=Path('E:/IcarusWorldAudit/2026-09-06/tactical-visibility-revision')


def main(out=None):
    out=out or REV/'split-v31-precise-parent-recovery-v1';out.mkdir(exist_ok=False)
    failure=REV/'split-connected-contact-v31-failure-v1/failure-arrays.npz';a=np.load(failure);xyz=a['2_xyz'];data=a['3_data']
    stage=REV/'split-connected-contact-stage-v31/family-declarations.json';f=next(f for f in json.loads(stage.read_text()) if f['edge']==200140)
    wp=REV/'display-warps-v1/split.display-warp.json.gz';w=json.loads(gzip.decompress(wp.read_bytes()));matrix=np.column_stack([w['projection']['axisU'],w['projection']['axisV']]);origin=np.array(w['projection']['origin']);inverse=np.linalg.inv(matrix)
    source=np.array(w['sourceNativeMeters']).reshape(-1,2)@matrix.T+origin;target=np.array(w['targetAttackSvg']).reshape(-1,2);cells=np.array(w['triangles']).reshape(-1,3)
    unwarp=explicit_warp(target,source-target,cells);forward=explicit_warp(source,target-source,cells)
    parts=region_fragments(data,f,unwarp,source_construction=native_source_rows(xyz,matrix,origin))
    bary=[];tri=[];regions=[];warps=[]
    for part,warp,region in parts:
        weights=part[:,3:];native=weights@xyz;native[:,:2]=(inverse_in_cell(part[:,:2],unwarp,warp)-origin)@inverse.T
        for j in range(1,len(part)-1):
            take=[0,j,j+1];bary.append(weights[take]);tri.append(native[take]);regions.append(region);warps.append(warp)
    bary=np.array(bary);tri=np.array(tri);regions=np.array(regions);warps=np.array(warps);parents=np.full(len(tri),991958);original=np.broadcast_to(xyz,tri.shape)
    partition=verify_source_partition(parents,bary,[991958]);expected=reconstruct_source_points(bary,original)
    packet=out/'recovered-parent.npz';np.savez_compressed(packet,triangles=tri,sourceBarycentrics=bary,regionCells=regions,warpCells=warps,sourceOriginal=xyz)
    mapping=verify_region_fragments(f,expected[:,:,:2]@matrix.T+origin,tri[:,:,:2]@matrix.T+origin,regions,warps,forward,
        np.array([[1/3,1/3,1/3]]),source_construction=dict(originalNativeTriangles=original,sourceBarycentrics=bary,projectionMatrix=matrix,projectionOrigin=origin,
        sourceParents=parents,regionCells=regions,inputHashes=dict(failure=sha(failure),declarations=sha(stage),displayWarp=sha(wp),packet=sha(packet))))
    report=dict(status='passed',failureSha256=sha(failure),frozenDeclarationsSha256=sha(stage),packetSha256=sha(packet),
        kernelSha256=sha(Path(__file__).with_name('finite_region_cells.py')),sourceParent=991958,family=200140,fragments=len(tri),
        sourcePartition=partition,mapping=mapping,maximumHeightErrorMeters=float(abs(tri[:,:,2]-expected[:,:,2]).max()),
        scope='Full failing source parent, original exact clipping and unchanged declarations. Source partition and independent stored-provenance continuous mapping gates. No tolerance or geometry change.')
    (out/'report.json').write_text(json.dumps(report,indent=2)+'\n');print(json.dumps({k:v for k,v in report.items() if k not in ['mapping','sourcePartition']},indent=2))


if __name__=='__main__':
    import argparse
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--output',type=Path)
    main(parser.parse_args().output)

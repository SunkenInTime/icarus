"""Verify every attached-bin face through the sealed finite wall field."""
import gzip
import json
from pathlib import Path

import numpy as np

from declare_split_legacy105_connected_region import ROOT, REV, sha
from exact_source_partition import prove_partition
from finite_region_cells import region_fragments
from native_region_source import native_source_rows
from tactical_alignment_composite import explicit_warp


def main():
    path=REV/'split-legacy105-connected-region-proposal-v7/region-declaration.json'
    family=json.loads(path.read_text())
    evidence=REV/'split-wall-bin7852-attachment-proposal-v1/source-attachment.npz'
    with np.load(evidence) as source:
        ids=source['binRawFaces'];triangles=source['binTriangles']
    wp=REV/'display-warps-v1/split.display-warp.json.gz'
    w=json.loads(gzip.decompress(wp.read_bytes()))
    matrix=np.column_stack((w['projection']['axisU'],w['projection']['axisV']))
    origin=np.array(w['projection']['origin'])
    ws=np.array(w['sourceNativeMeters']).reshape(-1,2)@matrix.T+origin
    wt=np.array(w['targetAttackSvg']).reshape(-1,2);wc=np.array(w['triangles']).reshape(-1,3)
    backward=explicit_warp(wt,ws-wt,wc)
    rows=[];saved_xyz=[];saved_bary=[];saved_parents=[];cells=[]
    max_x=-np.inf;max_z=0.;pieces=0
    for index,(raw_id,xyz) in enumerate(zip(ids,triangles)):
        data=np.column_stack((xyz[:,:2]@matrix.T+origin,xyz[:,2],np.eye(3)))
        parts=region_fragments(data,family,backward,source_construction=native_source_rows(xyz,matrix,origin))
        bary=[]
        for part,wcell,rcell in parts:
            # Output XY is in authored SVG space, before inverse W storage.
            max_x=max(max_x,float(part[:,0].max()))
            max_z=max(max_z,float(abs(part[:,2]-part[:,3:6]@xyz[:,2]).max()))
            for j in range(1,len(part)-1):
                selected=part[[0,j,j+1]]
                bary.append(selected[:,3:6]);saved_xyz.append(selected[:,:3]);saved_bary.append(selected[:,3:6])
                saved_parents.append(int(raw_id));cells.append([wcell,rcell])
        proof=prove_partition(np.array(bary))
        assert proof['passed'],(int(raw_id),proof)
        rows.append(dict(rawSourceFace=int(raw_id),fragments=len(bary),partition=proof));pieces+=len(bary)
        if (index+1)%100==0:print('checked',index+1,'of',len(ids),flush=True)
    assert max_x<=279.074+1e-10
    assert max_z<1e-12
    out=REV/'split-wall-bin7852-finite-review-v1';out.mkdir(exist_ok=False)
    np.savez_compressed(out/'finite-source-fragments.npz',mappedSvgAndOriginalZ=np.array(saved_xyz),sourceBarycentrics=np.array(saved_bary),rawSourceParents=np.array(saved_parents),warpAndRegionCells=np.array(cells))
    report=dict(declarationSha256=sha(path),sourcePacketSha256=sha(evidence),warpSha256=sha(wp),scriptSha256=sha(Path(__file__)),
        sourceFaces=len(ids),generatedFragments=pieces,maximumMappedXSvg=max_x,authoredWallXSvg=279.074,
        maximumOriginalZErrorMeters=max_z,allSourcePartitionsPassed=True,faces=rows,
        scope='Every original face passes through the unchanged finite field. Convex fragment bounds are on or behind the authored wall. Complete original source area remains represented, including collapsed fragments. Packed source UV and rendered contacts remain separate gates.')
    (out/'report.json').write_text(json.dumps(report,indent=2)+'\n')
    print(json.dumps({k:v for k,v in report.items() if k!='faces'},indent=2))


if __name__=='__main__':main()

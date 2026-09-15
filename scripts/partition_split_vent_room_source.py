"""Partition every raw vent-room parent through the held field without baking a pack."""
import gzip,json,time
from pathlib import Path
import numpy as np
from finite_region_cells import region_fragments
from native_region_source import native_source_rows
from authored_wall_profile_cells import inverse_in_cell
from tactical_alignment_composite import explicit_warp
from verify_normalized_wall_profiles import verify_source_partition,reconstruct_source_points
from lift_reviewed_wall_source_heights import sha

ROOT=Path('E:/IcarusWorldAudit/2026-09-06');REV=ROOT/'tactical-visibility-revision'


def main():
    out=REV/'split-vent-room-raw-partition-v3';out.mkdir(exist_ok=False)
    fp=REV/'split-vent-room-finite-field-experiment-v6/sealed-held-region-declaration.json'
    family=json.loads(fp.read_text());wp=REV/'display-warps-v1/split.display-warp.json.gz'
    w=json.loads(gzip.decompress(wp.read_bytes()))
    matrix=np.column_stack((w['projection']['axisU'],w['projection']['axisV']));origin=np.array(w['projection']['origin']);inverse=np.linalg.inv(matrix)
    ws=np.array(w['sourceNativeMeters']).reshape(-1,2)@matrix.T+origin
    wt=np.array(w['targetAttackSvg']).reshape(-1,2);wc=np.array(w['triangles']).reshape(-1,3)
    unwarp=explicit_warp(wt,ws-wt,wc)
    raw_path=ROOT/'supplemented-v2/world/split/geometry.npz';raw=np.load(raw_path)
    points,faces,uvs,materials=raw['points'],raw['faces'],raw['uvs'],raw['material_indices']
    raw_ids=np.array(family['reviewedSourceFaces'],dtype=np.int64);source=points[faces[raw_ids]]
    lower=np.array(family['box'][:2]);upper=np.array(family['box'][2:])
    all_projected=source[:,:,:2]@matrix.T+origin
    assert (all_projected>=lower).all() and (all_projected<=upper).all(), 'This audit requires full source ownership inside the field.'
    source_rows=[];native_rows=[];svg_rows=[];bary_rows=[];region_rows=[];warp_rows=[];uv_rows=[]
    start=time.monotonic()
    for index,(parent,xyz) in enumerate(zip(raw_ids,source)):
        projected=xyz.copy();projected[:,:2]=all_projected[index]
        data=np.column_stack((projected,np.eye(3)))
        fragments=region_fragments(data,family,unwarp,source_construction=native_source_rows(xyz,matrix,origin))
        for part,warp_cell,region_cell in fragments:
            bary=part[:,3:];physical=bary@xyz
            physical[:,:2]=(inverse_in_cell(part[:,:2],unwarp,warp_cell)-origin)@inverse.T
            for j in range(1,len(part)-1):
                ids=[0,j,j+1];source_rows.append(parent);native_rows.append(physical[ids]);svg_rows.append(part[ids,:2])
                bary_rows.append(bary[ids]);region_rows.append(region_cell);warp_rows.append(warp_cell)
                uv_rows.append(bary[ids]@uvs[parent])
        if (index+1)%100==0:print(json.dumps(dict(parents=index+1,total=len(raw_ids),fragments=len(source_rows),elapsedSeconds=round(time.monotonic()-start,2))),flush=True)
    parents=np.array(source_rows,dtype=np.int64);bary=np.array(bary_rows);native=np.array(native_rows);canonical=np.array(svg_rows)
    expected=reconstruct_source_points(bary,points[faces[parents]])
    zerr=float(abs(expected[:,:,2]-native[:,:,2]).max(initial=0))
    uvarray=np.array(uv_rows);uverr=float(abs(uvarray-np.einsum('nij,njk->nik',bary,uvs[parents])).max(initial=0))
    assert zerr<1e-10 and uverr<1e-10
    area=np.linalg.norm(np.cross(native[:,1]-native[:,0],native[:,2]-native[:,0]),axis=1)
    np.savez_compressed(out/'raw-source-fragments.npz',sourceFaces=parents,barycentrics=bary,
        trianglesNativeSourceZ=native,trianglesCanonicalSvg=canonical,regionCells=np.array(region_rows),
        warpCells=np.array(warp_rows),uvs=uvarray,materialIndices=materials[parents],
        collapsedPhysicalFaces=area<1e-12,originalSourceFaces=raw_ids)
    print('Saved all fragments; checking independent source coverage.',flush=True)
    partition=verify_source_partition(parents,bary,raw_ids.tolist())
    report=dict(sourceGeometrySha256=sha(raw_path),declarationSha256=sha(fp),warpSha256=sha(wp),
        scriptSha256=sha(Path(__file__)),fragmentFileSha256=sha(out/'raw-source-fragments.npz'),
        rawSourceFaces=len(raw_ids),fragments=len(parents),collapsedPhysicalFragments=int((area<1e-12).sum()),
        maximumOriginalZErrorMeters=zerr,maximumUvError=uverr,sourcePartition=partition,
        elapsedSeconds=time.monotonic()-start,
        scope='Complete declared raw parent partition through finite field and inverse W, including degenerate fragments. No source face is dropped. No packed material admission, floor flattening, or production candidate is claimed.',
        next='Composed original-height receiver rays and actual SVG artwork checks remain required before a bake.')
    (out/'partition-review.json').write_text(json.dumps(report,indent=2)+'\n')
    print(json.dumps({k:v for k,v in report.items() if k!='sourcePartition'}))


if __name__=='__main__':main()

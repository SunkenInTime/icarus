"""Compare finite-cell subdivision on the three largest barrier source parents."""
import gzip,json,time,hashlib
import numpy as np
from build_split_connected_tower import REV
from tactical_alignment_audit import pack
from tactical_alignment_composite import explicit_warp
from build_split_normalized_wall_families import cut
from finite_region_cells import region_fragments,partition_mesh
from region_partition_certificate import SourceCellCertificate
from authored_wall_profile_cells import inverse_in_cell
from exact_source_partition import prove_partition
from verify_region_mapping import verify_region_fragments


def main():
    out=REV/'split-barrier-finite-cell-prototype-v1';out.mkdir(exist_ok=True);source_path=REV/'global-ground-complete-v2/split/split.height.bin.gz';_,arrays=pack(source_path);families=json.loads((REV/'split-tower-connected-declarations-v28.json').read_text())['families'];family=next(f for f in families if f['edge']==200123);cert=SourceCellCertificate(family)
    w=json.loads(gzip.decompress((REV/'display-warps-v1/split.display-warp.json.gz').read_bytes()));matrix=np.column_stack((w['projection']['axisU'],w['projection']['axisV']));origin=np.array(w['projection']['origin']);s=np.array(w['sourceNativeMeters']).reshape(-1,2)@matrix.T+origin;t=np.array(w['targetAttackSvg']).reshape(-1,2);cells=np.array(w['triangles']).reshape(-1,3);unwarp=explicit_warp(t,s-t,cells);forward=explicit_warp(s,t-s,cells)
    old=np.load(REV/'split-wall-family-normalized-candidate-v28-partition-preflight.npz');probes=np.array([[i/8,j/8,(8-i-j)/8] for i in range(9) for j in range(9-i)]);rows=[]
    for parent in [1122016,1122017,1122105]:
        start=time.perf_counter();native=arrays['vertices'][arrays['faces'][parent]];data=native.copy();data[:,:2]=data[:,:2]@matrix.T+origin;inside,outside=cut(list(np.column_stack((data,np.eye(3)))),family['box']);original_callback=cert.callback(native,matrix,origin,parent)
        def callback(part,points,triangles,relevant):
            try:return original_callback(part,points,triangles,relevant)
            except Exception:
                (out/f'failure-{parent}.json').write_text(json.dumps(dict(native=native.tolist(),inside=np.array(inside).tolist(),part=part.tolist(),relevant=np.flatnonzero(relevant).tolist(),cells=points[triangles[relevant]].tolist()),indent=2));raise
        callback.exact_source_data=original_callback.exact_source_data
        source_parts=partition_mesh(np.array(inside),np.array(family['sourceVerticesSvg']),np.array(family['triangles']),containment_certificate=callback)
        fragments=region_fragments(np.array(inside),family,unwarp,containment_certificate=callback);elapsed=time.perf_counter()-start;all_bary=[];mapped=[];bary=[];region=[];display=[]
        for part,wcell,rcell in fragments:
            xy=inverse_in_cell(part[:,:2],unwarp,wcell)
            for j in range(1,len(part)-1):
                ids=[0,j,j+1];all_bary.append(part[ids,3:6]);bary.append(part[ids,3:6]);mapped.append(xy[ids]);region.append(rcell);display.append(wcell)
        for part in outside:
            part=np.array(part)
            for j in range(1,len(part)-1):all_bary.append(part[[0,j,j+1],3:6])
        bary=np.array(bary);mapped=np.array(mapped);region=np.array(region);display=np.array(display);original=np.repeat(native[None],len(bary),axis=0);source_points=(original[:,:1]+np.einsum('nij,njk->nik',bary[:,:,1:],original[:,1:]-original[:,:1]))[:,:,:2]@matrix.T+origin
        partition=prove_partition(np.array(all_bary));assert partition['passed'],partition
        proof=verify_region_fragments(family,source_points,mapped,region,display,forward,probes,source_construction=dict(originalNativeTriangles=original,sourceBarycentrics=bary,projectionMatrix=matrix,projectionOrigin=origin,sourceParents=np.full(len(bary),parent),regionCells=region,inputHashes=dict(sourcePackSha256=hashlib.sha256(source_path.read_bytes()).hexdigest())))
        row=dict(parent=parent,oldPreflightTriangles=int((old['parents']==parent).sum()),finiteSourcePolygons=len(source_parts),finiteOutputPolygons=len(fragments),finiteTriangles=len(all_bary),geometrySeconds=elapsed,sourcePartition=partition,mappedFieldProof=proof);rows.append(row);(out/f'parent-{parent}.json').write_text(json.dumps(row,indent=2));np.savez_compressed(out/f'parent-{parent}.npz',sourceBarycentrics=bary,actualSvg=mapped,regionCells=region,displayCells=display,allBarycentrics=np.array(all_bary));print({k:row[k] for k in ['parent','oldPreflightTriangles','finiteSourcePolygons','finiteOutputPolygons','finiteTriangles','geometrySeconds']},flush=True)
    (out/'summary.json').write_text(json.dumps(rows,indent=2))

if __name__=='__main__':main()

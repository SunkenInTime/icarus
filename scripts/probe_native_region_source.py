"""Original-native finite clipping gates on actual pipe/generator parents."""
import gzip
import hashlib
import importlib.util
import json
from pathlib import Path
import time

import numpy as np
from authored_wall_profile_cells import inverse_in_cell
from build_split_normalized_wall_families import cut
from finite_region_cells import region_fragments
from native_region_source import native_source_rows
from native_compact_wall_profiles import sha
from region_partition_certificate import SourceCellCertificate
from tactical_alignment_audit import pack
from tactical_alignment_composite import explicit_warp
from verify_normalized_wall_profiles import verify_source_partition
from verify_region_mapping import verify_region_fragments

REV=Path('E:/IcarusWorldAudit/2026-09-06/tactical-visibility-revision')


def main():
    out=REV/'native-region-source-provenance-gate-v1';out.mkdir(exist_ok=False)
    source_path=REV/'global-ground-complete-v2/split/split.height.bin.gz';_,a=pack(source_path)
    cfull=np.load(source_path.parent/'correspondence.npz')['sourceFaces']
    original=np.load(REV/'full-height-input-v1/split/source-correspondence.npz')['sourceFaces'][cfull]
    wp=REV/'display-warps-v1/split.display-warp.json.gz';w=json.loads(gzip.decompress(wp.read_bytes()))
    matrix=np.column_stack([w['projection']['axisU'],w['projection']['axisV']]);origin=np.array(w['projection']['origin'])
    ws=np.array(w['sourceNativeMeters']).reshape(-1,2)@matrix.T+origin;wt=np.array(w['targetAttackSvg']).reshape(-1,2);wc=np.array(w['triangles']).reshape(-1,3)
    forward=explicit_warp(ws,wt-ws,wc);backward=explicit_warp(wt,ws-wt,wc)
    paths=[REV/'split-pipe130-profile-region-proposal-v5/region-declaration.json',
           REV/'split-generator-connected-profile-proposal-v4/region-declaration.json']
    rows=[]
    for path in paths:
        family=json.loads(path.read_text());family['mappingType']='piecewise-affine-region-v1'
        ids=np.flatnonzero(np.isin(original,family['reviewedSourceFaces']))
        tri=a['vertices'][a['faces'][ids]];svg=tri[:,:,:2]@matrix.T+origin
        span=np.ptp(svg,axis=1);area=span[:,0]*span[:,1]
        chosen=np.unique(np.r_[ids[np.argsort(area)[-3:]],ids[np.argsort(span[:,0])[-3:]],ids[np.argsort(span[:,1])[-3:]],ids[np.linspace(0,len(ids)-1,4).astype(int)]])
        all_bary=[];all_parents=[];bary=[];native_tri=[];actual=[];rcells=[];dcells=[];mapped_parents=[];case_rows=[]
        start=time.perf_counter()
        for parent in chosen:
            native=a['vertices'][a['faces'][parent]];data=native.copy();data[:,:2]=data[:,:2]@matrix.T+origin
            inside,outside=cut(list(np.column_stack((data,np.eye(3)))),family['box'])
            if len(inside)<3:continue
            try:parts=region_fragments(np.array(inside),family,backward,source_construction=native_source_rows(native,matrix,origin))
            except Exception:
                (out/f'failed-{family["edge"]}-{parent}.json').write_text(json.dumps(dict(familyPath=str(path),parent=int(parent),native=native.tolist(),inside=np.array(inside).tolist()),indent=2));raise
            count=0
            for part,display,region in parts:
                xy=inverse_in_cell(part[:,:2],backward,display)
                for j in range(1,len(part)-1):
                    index=[0,j,j+1];weights=part[index,3:6]
                    all_bary.append(weights);all_parents.append(int(parent));bary.append(weights);native_tri.append(native)
                    actual.append(xy[index]);rcells.append(region);dcells.append(display);mapped_parents.append(int(parent));count+=1
            for part in outside:
                part=np.array(part)
                for j in range(1,len(part)-1):all_bary.append(part[[0,j,j+1],3:6]);all_parents.append(int(parent))
            case_rows.append(dict(parent=int(parent),originalSourceFace=int(original[parent]),outputTriangles=count))
        bary=np.array(bary);native_tri=np.array(native_tri);actual=np.array(actual);rcells=np.array(rcells);dcells=np.array(dcells)
        np.savez_compressed(out/f'family-{family["edge"]}.npz',barycentrics=bary,originalNativeTriangles=native_tri,actualSvg=actual,regionCells=rcells,displayCells=dcells,sourceParents=np.array(mapped_parents),allBarycentrics=np.array(all_bary),allParents=np.array(all_parents))
        partition=verify_source_partition(np.array(all_parents),np.array(all_bary),sorted(set(all_parents)))
        source_points=(native_tri[:,:1]+np.einsum('nij,njk->nik',bary[:,:,1:],native_tri[:,1:]-native_tri[:,:1]))[:,:,:2]@matrix.T+origin
        mapping=verify_region_fragments(family,source_points,actual,rcells,dcells,forward,np.array([[1/3]*3]),source_construction=dict(
            originalNativeTriangles=native_tri,sourceBarycentrics=bary,projectionMatrix=matrix,projectionOrigin=origin,
            sourceParents=np.array(mapped_parents),regionCells=rcells,inputHashes=dict(sourcePackSha256=sha(source_path),declarationSha256=sha(path))))
        report=dict(family=family['edge'],declarationSha256=sha(path),cases=case_rows,sourcePartition=partition,mappedField=mapping,elapsedSeconds=time.perf_counter()-start)
        (out/f'family-{family["edge"]}.json').write_text(json.dumps(report,indent=2));rows.append(report)
        print(dict(family=family['edge'],parents=len(case_rows),triangles=len(actual),elapsedSeconds=report['elapsedSeconds']),flush=True)
    # Old V29 finite implementation and default new path must agree exactly.
    frozen=REV/'v29-compiler-frozen-before-native-provenance/finite_region_cells.py'
    spec=importlib.util.spec_from_file_location('frozen_v29_finite',frozen);old=importlib.util.module_from_spec(spec);spec.loader.exec_module(old)
    barrier=next(f for f in json.loads((REV/'split-wall-family-normalized-candidate-v29/bindings.json').read_text())['families'] if f['edge']==200123)
    barrier_rows=[]
    for parent in [1122016,1122017,1122105]:
        native=a['vertices'][a['faces'][parent]];data=native.copy();data[:,:2]=data[:,:2]@matrix.T+origin
        inside,_=cut(list(np.column_stack((data,np.eye(3)))),barrier['box'])
        cert=SourceCellCertificate(barrier);callback=cert.callback(native,matrix,origin,parent)
        before=old.region_fragments(np.array(inside),barrier,backward,containment_certificate=callback)
        after=region_fragments(np.array(inside),barrier,backward,containment_certificate=callback)
        assert len(before)==len(after)
        for x,y in zip(before,after):assert x[1:]==y[1:];np.testing.assert_array_equal(x[0],y[0])
        barrier_rows.append(dict(parent=parent,fragments=len(after),bitwiseEqual=True))
        print(barrier_rows[-1],flush=True)
    (out/'summary.json').write_text(json.dumps(dict(sourcePackSha256=sha(source_path),scriptSha256=sha(Path(__file__)),families=rows,barrierDefaultControls=barrier_rows,productionMutation=False),indent=2))


if __name__=='__main__':main()

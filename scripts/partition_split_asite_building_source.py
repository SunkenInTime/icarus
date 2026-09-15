"""Full raw parent partition, retaining finite-field exterior source fragments."""
import gzip,json,time
from fractions import Fraction
from pathlib import Path
import numpy as np
from finite_region_cells import region_fragments,exact_initial_data,partition_mesh
from native_region_source import native_source_rows
from authored_wall_profile_cells import inverse_in_cell
from tactical_alignment_composite import explicit_warp
from verify_normalized_wall_profiles import verify_source_partition
from lift_reviewed_wall_source_heights import sha

ROOT=Path('E:/IcarusWorldAudit/2026-09-06');REV=ROOT/'tactical-visibility-revision'
out=REV/'split-asite-building-raw-partition-v6';out.mkdir(exist_ok=False)
fp=REV/'split-asite-building-connected-proposal-v6/region-declaration.json';f=json.loads(fp.read_text())
wp=REV/'display-warps-v1/split.display-warp.json.gz';w=json.loads(gzip.decompress(wp.read_bytes()));m=np.column_stack((w['projection']['axisU'],w['projection']['axisV']));o=np.array(w['projection']['origin']);inv=np.linalg.inv(m)
ws=np.array(w['sourceNativeMeters']).reshape(-1,2)@m.T+o;wt=np.array(w['targetAttackSvg']).reshape(-1,2);wc=np.array(w['triangles']).reshape(-1,3);unwarp=explicit_warp(wt,ws-wt,wc)
raw=ROOT/'supplemented-v2/world/split/geometry.npz';d=np.load(raw);points,faces,uvs,materials=d['points'],d['faces'],d['uvs'],d['material_indices']
all_ids=np.array(f['reviewedSourceFaces']);source=points[faces[all_ids]];projected=source.copy();projected[:,:,:2]=projected[:,:,:2]@m.T+o
admit=(projected[:,:,:2].max(1)>=f['box'][:2]).all(1)&(projected[:,:,:2].min(1)<=f['box'][2:]).all(1)
raw_ids=all_ids[admit];source=source[admit];projected=projected[admit]
prior=json.loads((REV/'split-wall-family-normalized-candidate-v30-cached-v1/bindings.json').read_text())
protected={str(x['edge']):sorted(set(x['originalSourceFaces'])&set(map(int,raw_ids))) for x in prior['families'] if x['edge'] != 17}
assert not any(protected.values()),protected
def cut(rows):
    outside=[]
    for axis,value,sign in [(0,f['box'][0],1),(0,f['box'][2],-1),(1,f['box'][1],1),(1,f['box'][3],-1)]:
        if not rows:break
        value=Fraction(value);inside=[];other=[]
        for a,b in zip(rows,rows[1:]+rows[:1]):
            av=(a[axis]-value)*sign;bv=(b[axis]-value)*sign
            (inside if av>=0 else other).append(a)
            if(av>=0)!=(bv>=0):
                t=av/(av-bv);q=[x+t*(y-x) for x,y in zip(a,b)];inside.append(q);other.append(q)
        rows=inside
        if len(other)>=3:outside.append(other)
    return rows,outside
parents=[];barys=[];physical=[];canonical=[];regions=[];warps=[];start=time.monotonic();outside_count=0
for index,(parent,xyz,svg) in enumerate(zip(raw_ids,source,projected)):
    data=np.c_[svg,np.eye(3)];construction=native_source_rows(xyz,m,o);inside,outside=cut(exact_initial_data(data,source_construction=construction))
    pieces=[]
    if len(inside)>=3:
        d=np.array([[float(v)for v in row]for row in inside])
        for part,wc_id,rc_id in region_fragments(d,f,unwarp,source_construction=construction):
            b=part[:,3:];q=b@xyz;q[:,:2]=(inverse_in_cell(part[:,:2],unwarp,wc_id)-o)@inv.T
            pieces.append((b,q,part[:,:2],wc_id,rc_id))
    for part in outside:
        d=np.array([[float(v)for v in row]for row in part])
        for frag,wc_id,weights in partition_mesh(d,ws,wc,exact_rows=part,return_weights=True):
            b=frag[:,3:];pieces.append((b,b@xyz,weights@wt[wc[wc_id]],wc_id,-1));outside_count+=1
    for b,q,shown,wc_id,rc_id in pieces:
        for j in range(1,len(b)-1):
            ids=[0,j,j+1];parents.append(parent);barys.append(b[ids]);physical.append(q[ids]);canonical.append(shown[ids]);regions.append(rc_id);warps.append(wc_id)
    if (index+1)%100==0:print(json.dumps(dict(parents=index+1,total=len(raw_ids),fragments=len(parents),elapsed=round(time.monotonic()-start,2))),flush=True)
parents=np.array(parents);barys=np.array(barys);physical=np.array(physical);canonical=np.array(canonical);uv=np.einsum('nij,njk->nik',barys,uvs[parents]);area=np.linalg.norm(np.cross(physical[:,1]-physical[:,0],physical[:,2]-physical[:,0]),axis=1)
np.savez_compressed(out/'raw-source-fragments.npz',sourceFaces=parents,barycentrics=barys,trianglesNativeSourceZ=physical,trianglesCanonicalSvg=canonical,
    regionCells=np.array(regions),warpCells=np.array(warps),uvs=uv,materialIndices=materials[parents],collapsedPhysicalFaces=area<1e-12,originalSourceFaces=raw_ids)
partition=verify_source_partition(parents,barys,raw_ids.tolist());zerr=float(abs(physical[:,:,2]-np.einsum('nij,nj->ni',barys,points[faces[parents],2])).max())
report=dict(sourceGeometrySha256=sha(raw),declarationSha256=sha(fp),warpSha256=sha(wp),scriptSha256=sha(Path(__file__)),fragmentFileSha256=sha(out/'raw-source-fragments.npz'),
    reviewedSourceFaces=len(all_ids),rawSourceFaces=len(raw_ids),unaffectedOutsideParentFaces=all_ids[~admit].tolist(),protectedDistantFamilyRawParentIntersection=protected,
    fragments=len(parents),collapsedPhysicalFragments=int((area<1e-12).sum()),outsideFieldPolygons=outside_count,maximumOriginalZErrorMeters=zerr,sourcePartition=partition,
    elapsedSeconds=time.monotonic()-start,status='Held raw partition of the frozen V6 building proposal. Outside pieces preserve source XYZ. Original material admission and composed ray tests remain required.')
(out/'partition-review.json').write_text(json.dumps(report,indent=2)+'\n');print(json.dumps({k:v for k,v in report.items()if k not in ['sourcePartition','unaffectedOutsideParentFaces']}))

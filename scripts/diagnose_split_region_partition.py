"""Stage-by-stage source barycentric area for a rejected region parent."""
import gzip,json
import numpy as np
import shapely
from build_split_connected_tower import REV
from tactical_alignment_audit import pack
from tactical_alignment_composite import explicit_warp
from authored_region_cells import partition_mesh,barycentric
from build_split_normalized_wall_families import cut


def review(parts):
    triangles=[];invalid=[]
    for index,part in enumerate(parts):
        polygon=shapely.Polygon(part[:,4:6])
        if not polygon.is_valid:invalid.append(index)
        triangles.extend(part[[0,j,j+1],4:6] for j in range(1,len(part)-1))
    polygons=shapely.polygons(np.array(triangles));area=shapely.area(polygons).sum();union=shapely.union_all(polygons).area
    return dict(parts=len(parts),fanTriangles=len(triangles),fanArea=float(area),unionArea=float(union),overlap=float(area-union),invalidPolygons=invalid)


def main():
    candidate=REV/'split-wall-family-normalized-candidate-v22';out=candidate/'partition-stage-diagnostic';out.mkdir(exist_ok=True)
    family=next(f for f in json.loads((candidate/'bindings.json').read_text())['families'] if f['edge']==200190)
    _,arrays=pack(REV/'global-ground-complete-v2/split/split.height.bin.gz')
    w=json.loads(gzip.decompress((REV/'display-warps-v1/split.display-warp.json.gz').read_bytes()))
    a=np.column_stack((w['projection']['axisU'],w['projection']['axisV']));o=np.array(w['projection']['origin']);s=np.array(w['sourceNativeMeters']).reshape(-1,2)@a.T+o;t=np.array(w['targetAttackSvg']).reshape(-1,2);warp=explicit_warp(t,s-t,np.array(w['triangles']).reshape(-1,3))
    xyz=arrays['vertices'][arrays['faces'][1817409]].copy();xyz[:,:2]=xyz[:,:2]@a.T+o
    data=np.column_stack((xyz,np.eye(3)));inside,outside=cut(list(data),family['box']);inside=np.array(inside)
    source=np.array(family['sourceVerticesSvg']);target=np.array(family['targetVerticesSvg']);cells=np.array(family['triangles'])
    parts=partition_mesh(inside,source,cells);report=dict(input=data.tolist(),clip=review([inside,*[np.array(p) for p in outside]]),sourceCells=review([p for p,_ in parts]),perSourceCell=[])
    all_final=[]
    for part,cell in parts:
        canonical=part.copy();canonical[:,:2]=barycentric(part[:,:2],source[cells[cell]])@target[cells[cell]]
        final=partition_mesh(canonical,warp.points,warp.tri.simplices);all_final.extend(p for p,_ in final)
        row=dict(cell=cell,before=review([part]),after=review([p for p,_ in final]),canonical=canonical.tolist())
        if row['after']['overlap']>1e-10 or row['after']['invalidPolygons']:
            row['finalParts']=[dict(warpCell=c,data=p.tolist()) for p,c in final]
        report['perSourceCell'].append(row)
    report['afterWarp']=review(all_final)
    (out/'stages.json').write_text(json.dumps(report,indent=2));np.savez_compressed(out/'input.npz',data=data)
    print({k:v for k,v in report.items() if k not in ['input','perSourceCell']})
    print([(r['cell'],r['before'],r['after']) for r in report['perSourceCell'] if r['after']['overlap']>1e-10 or r['after']['invalidPolygons']])


if __name__=='__main__':main()

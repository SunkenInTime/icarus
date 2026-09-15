"""Separate source-cell subdivision from later W-cell subdivision on large parents."""
import gzip,inspect,json
import numpy as np
import authored_region_cells as module
from build_split_connected_tower import REV
from build_split_normalized_wall_families import cut
from tactical_alignment_audit import pack
from region_partition_certificate import SourceCellCertificate


def main():
    out=REV/'split-barrier-subdivision-growth-v1';family=next(f for f in json.loads((REV/'split-tower-connected-declarations-v28.json').read_text())['families'] if f['edge']==200123);_,a=pack(REV/'global-ground-complete-v2/split/split.height.bin.gz');w=json.loads(gzip.decompress((REV/'display-warps-v1/split.display-warp.json.gz').read_bytes()));matrix=np.column_stack((w['projection']['axisU'],w['projection']['axisV']));origin=np.array(w['projection']['origin']);cert=SourceCellCertificate(family);source=np.array(family['sourceVerticesSvg']);cells=np.array(family['triangles']);rows=[]
    for parent in [1122017,1122105]:
        tri=a['vertices'][a['faces'][parent]];data=tri.copy();data[:,:2]=data[:,:2]@matrix.T+origin;inside,outside=cut(list(np.column_stack((data,np.eye(3)))),family['box']);history=[]
        code=inspect.getsource(module.partition_mesh).replace('        parts=updated','        parts=updated\n        history.append(dict(edge=[int(a),int(b)],pieces=len(parts)))')
        ns=dict(module.__dict__);ns['history']=history;exec(code,ns)
        parts=ns['partition_mesh'](np.array(inside),source,cells,containment_certificate=cert.callback(tri,matrix,origin,parent));fans=sum(len(p)-2 for p,c in parts);area=0.;zero=0
        for p,c in parts:
            xy=p[:,4:6];d=xy[1:]-xy[0]
            values=abs(d[:-1,0]*d[1:,1]-d[:-1,1]*d[1:,0])/2;area+=values.sum();zero+=int((values==0).sum())
        row=dict(parent=parent,inputVertices=len(inside),outsidePolygons=len(outside),sourcePolygons=len(parts),sourceFanTriangles=fans,zeroSourceAreaFans=zero,summedSourceArea=float(area),actualCells=len({c for p,c in parts}),history=history);rows.append(row);(out/f'parent-{parent}-source-stages.json').write_text(json.dumps(row,indent=2));print({k:v for k,v in row.items() if k!='history'},flush=True)
        np.savez_compressed(out/f'parent-{parent}-source-pieces.npz',lengths=np.array([len(p) for p,c in parts]),data=np.concatenate([p for p,c in parts]),cells=np.array([c for p,c in parts]))
    (out/'source-stage-summary.json').write_text(json.dumps(rows,indent=2))

if __name__=='__main__':main()

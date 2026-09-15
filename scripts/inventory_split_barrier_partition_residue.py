"""Diagnostic inventory only: retain every strict partition failure for proof."""
import gzip,inspect,json
import numpy as np
import authored_region_cells as module
from build_split_connected_tower import REV
from build_split_normalized_wall_families import cut
from tactical_alignment_audit import pack
from tactical_alignment_composite import explicit_warp


def main():
    out=REV/'split-barrier-partition-residue-inventory-v1';out.mkdir(exist_ok=True)
    family=json.loads((REV/'split-barrier-corridor-region-proposal-v4/region-declaration.json').read_text())
    _,arrays=pack(REV/'global-ground-complete-v2/split/split.height.bin.gz');full=np.load(REV/'full-height-input-v1/split/source-correspondence.npz')['sourceFaces'];control=np.load(REV/'global-ground-complete-v2/split/correspondence.npz')['sourceFaces'];original=full[control]
    selected=np.flatnonzero(np.isin(original,family['reviewedSourceFaces']))
    w=json.loads(gzip.decompress((REV/'display-warps-v1/split.display-warp.json.gz').read_bytes()));a=np.column_stack((w['projection']['axisU'],w['projection']['axisV']));o=np.array(w['projection']['origin']);s=np.array(w['sourceNativeMeters']).reshape(-1,2)@a.T+o;t=np.array(w['targetAttackSvg']).reshape(-1,2);warp=explicit_warp(t,s-t,np.array(w['triangles']).reshape(-1,3))
    records=[];state={}
    def failure(part,coords,relevant,points):
        candidates=[]
        for cell in np.flatnonzero(relevant):
            weights=module.barycentric(part[:,:2],coords[cell]);tri=coords[cell];d=tri[1]-tri[0];e=tri[2]-tri[0];area=abs(d[0]*e[1]-d[1]*e[0]);lengths=np.linalg.norm(tri[[2,0,1]]-tri[[1,2,0]],axis=1);residual=float(np.max(np.maximum(-weights,0)*(area/lengths)))
            candidates.append((residual,int(cell),float(weights.min())))
        residue,cell,minimum=min(candidates);assert residue<1e-10, ('Diagnostic encountered a material crossing',residue)
        phase='display-W' if len(points)==len(warp.points) and np.array_equal(points,warp.points) else 'source-region'
        records.append(dict(controlParent=state['parent'],originalSourceFace=int(original[state['parent']]),phase=phase,cell=cell,doubleMinimum=minimum,maximumHalfplaneResidualSvg=residue,part=part[:,:6].tolist(),cellTriangleSvg=coords[cell].tolist()))
        return [cell]
    code=inspect.getsource(module.partition_mesh).replace("if not chosen:raise ValueError('Region piece has no containing cell')",'if not chosen:chosen=failure(part,coords,relevant,points)')
    ns=dict(module.__dict__);ns['failure']=failure;exec(code,ns)
    code=inspect.getsource(module.region_fragments).replace("if target_barycentrics(final[:,:2],warp,warp_cell).min() < -1e-8:raise ValueError('Region fragment crosses W cell')", "if target_barycentrics(final[:,:2],warp,warp_cell).min() < -1e-8:state.setdefault('secondaryWChecks',0);state['secondaryWChecks']+=1")
    # Keep the secondary check counter scoped to actual failures.
    code=code.replace("if target_barycentrics(final[:,:2],warp,warp_cell).min() < -1e-8:state.setdefault('secondaryWChecks',0);state['secondaryWChecks']+=1", "if target_barycentrics(final[:,:2],warp,warp_cell).min() < -1e-8:\n                state['secondaryWChecks']=state.get('secondaryWChecks',0)+1")
    ns['state']=state;exec(code,ns)
    for index,parent in enumerate(selected):
        state['parent']=int(parent);xyz=arrays['vertices'][arrays['faces'][parent]].copy();xyz[:,:2]=xyz[:,:2]@a.T+o;inside,_=cut(list(np.column_stack((xyz,np.eye(3)))),family['box'])
        if len(inside)>=3:ns['region_fragments'](np.array(inside),family,warp)
        if index%1000==0:print(index,len(selected),'failures',len(records),flush=True)
    report=dict(diagnosticOnly=True,sourceParents=len(selected),records=records,secondaryWChecks=state.get('secondaryWChecks',0));(out/'inventory.json').write_text(json.dumps(report,indent=2));print('DONE',len(records),report['secondaryWChecks'],flush=True)

if __name__=='__main__':main()

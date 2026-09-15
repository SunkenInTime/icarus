"""Source-local Breeze stair pairs avoiding the tunnel's bent footprint."""
import json
import hashlib
import numpy as np
import shapely
from probe_source_floor_regressions import load_support
from probe_split_audited_roles import main as run
from audit_split_floor_roles import REV

def main():
    out=REV/'breeze-audited-floor-role-proposals-v1'
    proposal=out/'breeze.floor-role-proposals.json';roles=json.loads(proposal.read_text())
    support=load_support(REV,'breeze',True)
    navids=support.detailed_navigation_indices;navcenters=support.points[navids].mean(axis=1)
    cases=[]
    seeds=[(5723,'b-site-stairs',[66.8,45.],[69.8,45.]),(5471,'ruins-stairs',[39.5,47.],[45.3,47.]),(5486,'tunnel-west-stairs',[44.,31.],[49.,31.]),(5486,'tunnel-south-stairs',[62.,19.],[62.,25.])]
    for obj,label,a,b in seeds:
        row=next(r for r in roles['records'] if r['sourceObjectIndex']==obj)
        ids=np.array([f['supportIndex'] for f in row['faces'] if f['proposed']])
        owners,local=shapely.STRtree(support.original_polygons[ids]).query(shapely.points(navcenters[:,:2]),predicate='intersects')
        height=np.sum(navcenters[owners,:2]*support.planes[ids[local],:2],axis=1)+support.planes[ids[local],2]
        valid=abs(height-navcenters[owners,2])<=.35
        owners,local,height=owners[valid],local[valid],height[valid]
        points=np.column_stack((navcenters[owners,:2],height))
        selected=[int(np.argmin(np.linalg.norm(points[:,:2]-seed,axis=1))) for seed in (a,b)]
        for direction,(first,last) in enumerate((selected,selected[::-1])):
            origin=points[first]+[0,0,1.75];target=points[last];vector=target[:2]-origin[:2];length=float(np.linalg.norm(vector));axis=vector/length
            cases.append(dict(id=f'{label}-{direction}',query=[*origin,*axis,length+.5,0],sourceObjectIndex=obj,originKind='source-surface-at-detailed-nav-center',originSupportIndex=int(ids[local[first]]),originFullPackFace=int(support.source_ids[ids[local[first]]]),navSupportIndex=int(navids[owners[first]]),targetSurfacePoint=target.tolist(),evidence='Two actual detailed-nav centers with exact source floor heights selected near the visually inspected local stair run. Ground mesh and elevation planes remain independent.',visualSeedNativeXY=[a,b],seedDistanceMeters=[float(np.linalg.norm(points[s,:2]-seed)) for s,seed in zip(selected,(a,b))]))
    path=out/'local-stair-input-fixtures.json'
    path.write_text(json.dumps(dict(roleManifestSha256=hashlib.sha256(proposal.read_bytes()).hexdigest(),cases=cases),indent=2))
    run('breeze','v1',path,False)
if __name__=='__main__':main()

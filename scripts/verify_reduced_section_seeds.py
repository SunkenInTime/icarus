"""Compare certified endpoint removal with the frozen all-section cone mesh."""
import hashlib
import json
import math
import numpy as np
from compile_redundant_section_seeds import REV
import probe_moving_floor_cones as cones

def run(reuse=False):
    seed_path=REV/'redundant-section-seeds-v1/split.npz'
    mask=np.load(seed_path)['keepEndpoints']
    original=cones.seed_angles
    def reduced(arrays,origin,heading,aperture,distance,include_sections):
        arrays={**arrays,'segments':arrays['segments'][mask]}
        return original(arrays,origin,heading,aperture,distance,include_sections)
    cones.seed_angles=reduced
    directory=REV/'moving-floor-cone-reduced-seeds-v1'
    if not reuse:
        cones.run(REV,8,128,.01,4096,True,directory.name)
    before=json.loads((REV/'moving-floor-cone-global-interval-v2/split.json').read_text())
    after=json.loads((directory/'split.json').read_text())
    comparisons=[]
    for old,new in zip(before['records'],after['records']):
        source_mesh=np.array(old['variants'][0]['mesh']);target_mesh=np.array(new['variants'][0]['mesh'])
        origin=np.array(old['origin'])[:2];heading=old['headingRadians']
        def polar(mesh):
            points=np.vstack([mesh[:,1],mesh[-1,2]])-origin
            angles=heading+(np.arctan2(points[:,1],points[:,0])-heading+math.pi)%(2*math.pi)-math.pi
            return angles,np.linalg.norm(points,axis=1)
        angles,ranges=polar(source_mesh);new_angles,new_ranges=polar(target_mesh);errors=[]
        for angle,distance in zip(angles,ranges):
            index=max(0,min(len(new_angles)-2,int(np.searchsorted(new_angles,angle)-1)))
            predicted=cones.radial_chord(new_angles[index],new_ranges[index],new_angles[index+1],new_ranges[index+1],angle)
            errors.append(abs(predicted-distance))
        comparisons.append(dict(frame=old['frame'],oldQueries=old['variants'][0]['queryCount'],newQueries=new['variants'][0]['queryCount'],
                                oldMeshVertices=len(angles),maximumOldVertexErrorMeters=float(max(errors)),oldVerticesAboveTolerance=int(sum(error>.01 for error in errors))))
    report=dict(seedDataSha256=hashlib.sha256(seed_path.read_bytes()).hexdigest(),comparisons=comparisons,
                limitation='Only certified redundant endpoint removal. Underlying all-section mesh and adaptive refinement do not prove complete angular event coverage.')
    (directory/'comparison.json').write_text(json.dumps(report,indent=2)+'\n')
    print(json.dumps(report),flush=True)
if __name__=='__main__':
    import sys
    run('--reuse' in sys.argv)

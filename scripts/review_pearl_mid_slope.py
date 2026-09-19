import sys,json,hashlib
from pathlib import Path
sys.path.insert(0,str(Path('scripts').resolve()))
import numpy as np
import shapely
from gameplay_standing_volumes import StandingVolumes
from audit_icebox_regional_floors import measure_obligation
v=StandingVolumes('pearl');known=len(v.rows)
meta_path=Path('work/pearl-all-v4/source-colliders.json')
archive_path=meta_path.with_suffix('.npz')
meta=json.loads(meta_path.read_bytes());archive=np.load(archive_path)
assert not v.unresolved,v.unresolved
for i in range(known):
    assert v.rows[i]['id']==meta[i]['id']
    np.testing.assert_allclose(v.triangles[i],archive[str(i)],atol=1e-10,rtol=0)
for i in range(known,len(meta)):
    v.rows.append(meta[i]);v.triangles.append(archive[str(i)]);v.equations.append(None)
b=np.array([r['bounds'] for r in v.rows]);v.tree=shapely.STRtree(shapely.box(b[:,0,0],b[:,0,1],b[:,1,0],b[:,1,1]))
# This entire collision body defines the scope, not a box around the test point.
lo,hi=np.array(v.rows[297]['bounds']);region=shapely.box(*(lo[:2]-.5),*(hi[:2]+.5))
result=measure_obligation(('volume-297',{'sourceCollision':v.rows[297]['id']},[297]),v,known,region,{})
result['sourceInputs']={str(p):hashlib.sha256(p.read_bytes()).hexdigest() for p in [meta_path,archive_path,Path('scripts/audit_icebox_regional_floors.py')]}
result['accountedCollisionBodies']=len(v.rows)
result['pointNative']=[41.96809419,-8.2326997]
result['pointCovered']=any(shapely.from_geojson(json.dumps(d['nativeGeometry'])).covers(shapely.Point(result['pointNative'])) for d in result['domains'])
Path('work/pearl-cutoff-2026-09-18/measured.json').write_text(json.dumps(result,indent=2))
print(result['row'],result['pointCovered'],flush=True)

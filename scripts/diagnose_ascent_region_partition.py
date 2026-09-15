"""Read-only reproduction of an unassigned source region fragment."""
import json,sys
from pathlib import Path
import numpy as np
from authored_region_cells import barycentric
from authored_wall_profile_cells import partition_linear
from prepare_ascent_connected_corners import REV

p=Path(sys.argv[1]) if len(sys.argv)>1 else REV/'ascent-connected-component5-candidate-v4-failed-partition.json'
d=json.loads(p.read_text());family=json.loads(Path(d['declaration']).read_text())['families'][0]
points=np.array(family['sourceVerticesSvg']);triangles=np.array(family['triangles']);coords=points[triangles];data=np.array(d['polygon'])
relevant=(coords.max(1)>=data[:,:2].min(0)-1e-10).all(1)&(coords.min(1)<=data[:,:2].max(0)+1e-10).all(1)
edges=sorted(set(tuple(sorted(e)) for t in triangles[relevant] for e in zip(t,np.roll(t,-1))))
parts=[data]
for a,b in edges:
    origin=points[a];v=points[b]-origin;normal=np.array([-v[1],v[0]])
    if np.linalg.norm(normal)<1e-12:continue
    parts=[part for old in parts for part in partition_linear(old,origin,normal,[0.])]
bad=[]
for part in parts:
    candidates=[]
    for cell in np.flatnonzero(relevant):
        tri=coords[cell];old=barycentric(part[:,:2],tri)
        uv=np.linalg.solve((tri[1:]-tri[0]).T,(part[:,:2]-tri[0]).T).T
        anchored=np.column_stack((1-uv.sum(1),uv))
        candidates.append(dict(cell=int(cell),minimum=float(old.min()),anchoredMinimum=float(anchored.min()),triangle=tri.tolist(),condition=float(np.linalg.cond((tri[1:]-tri[0]).T))))
    if max(c['minimum'] for c in candidates)<-1e-8:bad.append(dict(part=part.tolist(),candidates=sorted(candidates,key=lambda c:-c['minimum'])[:4]))
report=dict(source=d,partCount=len(parts),bad=bad)
p.with_name(p.stem+'-diagnostic.json').write_text(json.dumps(report,indent=2)+'\n')
print(json.dumps(report,indent=2))

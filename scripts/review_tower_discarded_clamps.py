"""Inventory nontrivial tower source fragments collapsed past shared endpoints."""
import gzip,json
from pathlib import Path
import numpy as np
from tactical_alignment_audit import pack
from verify_normalized_wall_profiles import profile_frame
from native_compact_wall_profiles import sha
REV=Path('E:/IcarusWorldAudit/2026-09-06/tactical-visibility-revision');folder=REV/'split-wall-family-normalized-candidate-v14';bindings=json.loads((folder/'bindings.json').read_text());source=Path(bindings['sourceBackup']);_,a=pack(source);p=np.load(folder/'normalized-face-provenance.npz');c2f=np.load(source.parent/'correspondence.npz')['sourceFaces'];full_original=np.load(REV/'full-height-input-v1/split/source-correspondence.npz')['sourceFaces'];w=json.loads(gzip.decompress((REV/'display-warps-v1/split.display-warp.json.gz').read_bytes()));matrix=np.column_stack((w['projection']['axisU'],w['projection']['axisV']));origin=np.array(w['projection']['origin']);families={f['edge']:f for f in bindings['families'] if 'sharedSourceJoins' in f};groups={}
for parent,edge,bary in zip(p['discardedSourceFaces'],p['discardedEdges'],p['discardedBarycentrics']):
    parent=int(parent);edge=int(edge)
    if edge not in families:continue
    triangle=a['vertices'][a['faces'][parent]];part=bary@triangle;area=float(np.linalg.norm(np.cross(part[1]-part[0],part[2]-part[0]))*.5)
    if area<1e-10:continue
    f=families[edge];o,t,n=profile_frame(f,'source');svg=part[:,:2]@matrix.T+origin;along=(svg-o)@t;lo,hi=f['sourceAlong'];beyond=min(along)-hi if min(along)>hi+1e-5 else lo-max(along) if max(along)<lo-1e-5 else 0
    if beyond<=0:continue
    raw=int(full_original[c2f[parent]]);key=(edge,raw);row=groups.setdefault(key,dict(edge=edge,originalSourceFace=raw,controlParents=[],discardedPhysicalAreaMeters2=0.,minimumBeyondEndpointSvg=float('inf'),fragments=[]));row['controlParents'].append(parent);row['discardedPhysicalAreaMeters2']+=area;row['minimumBeyondEndpointSvg']=min(row['minimumBeyondEndpointSvg'],float(beyond));row['fragments'].append(dict(sourceSvgRelativeZ=np.column_stack((svg,part[:,2])).tolist(),along=along.tolist()))
report=dict(scope=__doc__,candidateBindingsSha256=sha(folder/'bindings.json'),provenanceSha256=sha(folder/'normalized-face-provenance.npz'),scriptSha256=sha(Path(__file__)),groups=list(groups.values()),limitations=['These are review candidates, not automatic ownership errors. Wall-attached depth may intentionally collapse onto a reviewed corner.','Only discarded triangles wholly past a declared endpoint are examined; missing unadmitted families and partially clamped profiles require separate review.'])
out=REV/'split-tower-independent-review-v14/clamp-discard-review.json';assert not out.exists();out.write_text(json.dumps(report,indent=2)+'\n');print(json.dumps([{k:v for k,v in row.items() if k not in ['fragments','controlParents']} for row in groups.values()],indent=2))

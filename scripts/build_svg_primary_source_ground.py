"""Build a reviewable primary-ground overlay from named extracted floor meshes.

Floor triangles provide Z only. They never become view blockers. Where stacked
floors overlap, prefer the surface closest to the existing navigation sheet;
review the resulting field before adopting it. Preserve fallback where source
floors are absent, and report those gaps rather than fabricating new surfaces.
"""
import argparse
import gzip
import json
from pathlib import Path
import re

import numpy as np
import shapely

from audit_svg_source_height_associations import ROOT, REV, sha


def build(name, output):
    source=ROOT/f'supplemented-v2/world/{name}/geometry.npz'
    archive=np.load(source);points,faces=archive['points'],archive['faces']
    metadata=json.loads(source.with_suffix('.json').read_text())['objects']
    base_path=REV/f'global-ground-v1/{name}.tactical-ground.json.gz'
    base=json.loads(gzip.decompress(base_path.read_bytes()))
    vertices=np.array(base['vertices']).reshape(-1,3)
    triangles=vertices[np.array(base['triangles']).reshape(-1,3)]
    base_tree=shapely.STRtree(shapely.polygons(triangles[:,:,:2]))
    planes=np.linalg.solve(np.concatenate([triangles[:,:,:2],np.ones((len(triangles),3,1))],axis=2),triangles[:,:,2,None])[:,:,0]
    source_triangles=[];source_ids=[];object_ids=[];objects=[]
    for oid,obj in enumerate(metadata):
        label=obj['path'].split('/')[1].lower()
        if not re.search(r'floor|ground',label):continue
        if any(x in label for x in ('trash','decal','leaf','leaves','foliage','flower','dirt','rubble','scatter','gravel','pebble','detail','vista','roof','ceiling','light')):continue
        ids=np.arange(obj['firstFace'],obj['firstFace']+obj['faceCount'])
        t=points[faces[ids]].astype(float)
        n=np.cross(t[:,1]-t[:,0],t[:,2]-t[:,0]);length=np.linalg.norm(n,axis=1)
        # Mirrored source instances can reverse winding. Surface selection
        # uses navigation proximity rather than the triangle normal's sign.
        keep=(abs(n[:,2])>.65*length)&(length>1e-10)
        source_triangles.extend(t[keep]);source_ids.extend(ids[keep]);object_ids.extend([oid]*int(keep.sum()))
        if keep.any():objects.append(dict(object=oid,path=obj['path'],upwardFaces=int(keep.sum())))
    if not source_triangles:raise ValueError(('No named source floors',name))
    st=np.array(source_triangles);centers=st.mean(axis=1)
    matches=base_tree.query(shapely.points(centers[:,:2]),predicate='intersects')
    reference=np.full(len(st),np.nan)
    # The input primary field is ordered; choose the same first triangle as runtime.
    order=np.lexsort((matches[1],matches[0]));matches=matches[:,order]
    first=np.r_[True,np.diff(matches[0])!=0];m=matches[:,first]
    reference[m[0]]=np.sum(planes[m[1],:2]*centers[m[0],:2],axis=1)+planes[m[1],2]
    error=np.abs(centers[:,2]-reference)
    keep=np.isfinite(reference)&(error<=4)
    ids=np.flatnonzero(keep)
    # Quantized priority only, never quantized coordinates/heights. Stable face
    # identity breaks ties between coincident floor sheets deterministically.
    ids=ids[np.lexsort((np.array(source_ids)[ids],np.round(error[ids],3)))]
    accepted=st[ids]
    combined=np.concatenate([accepted,triangles])
    unique,inverse=np.unique(combined.reshape(-1,3),axis=0,return_inverse=True)
    result=dict(version=1,map=name,coordinateSpace='native-meters',
                vertices=unique.reshape(-1).tolist(),triangles=inverse.reshape(-1).tolist(),
                reviewStatus='pending',sourceFloorTriangles=len(accepted),fallbackTriangles=len(triangles),
                policy='Ordered source-floor overlay selected against primary navigation, followed by original interpolation fallback. No wall XY.',
                sourceGeometrySha256=sha(source),baseGroundSha256=sha(base_path))
    output.mkdir(parents=True,exist_ok=True)
    file=output/f'{name}.json.gz';file.write_bytes(gzip.compress(json.dumps(result,separators=(',',':'),allow_nan=False).encode(),mtime=0))
    report=dict(map=name,sourceObjects=objects,acceptedSourceFaces=np.array(source_ids)[ids].tolist(),
                acceptedSourceObjects=np.array(object_ids)[ids].tolist(),
                rejectedSourceFaces=int((~keep).sum()),acceptedSourceFacesCount=len(ids),
                vertices=len(unique),triangles=len(combined),gzipBytes=file.stat().st_size,
                maximumAcceptedCentroidCorrectionMeters=float(error[ids].max()),
                reviewStatus='pending',limitations=['Source-only floor names are incomplete. Uncovered regions retain navigation interpolation.',
                    'Stacked source surfaces are selected by navigation proximity at triangle centroid; inspect elevated/underpass cases.',
                    'Raw source floor triangles do not define or alter SVG wall placement.'])
    (output/f'{name}-evidence.json').write_text(json.dumps(report,indent=2)+'\n')
    print(json.dumps({k:v for k,v in report.items() if k not in ['sourceObjects','acceptedSourceFaces','acceptedSourceObjects']}),flush=True)


if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--maps',nargs='+',required=True);p.add_argument('--out',type=Path,required=True);a=p.parse_args()
    for name in a.maps:build(name,a.out)

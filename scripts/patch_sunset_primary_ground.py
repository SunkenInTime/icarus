"""Correct reviewed flat Sunset floors without importing any wall geometry."""
import gzip
import json

import numpy as np
import shapely

from audit_svg_source_height_associations import ROOT, REV
from build_split_svg_ground import replace_ground_footprint


def main():
    source=ROOT/'supplemented-v2/world/sunset/geometry.npz'
    raw=np.load(source)
    objects=json.loads(source.with_suffix('.json').read_text())['objects']
    base=json.loads(gzip.decompress((REV/'global-ground-v1/sunset.tactical-ground.json.gz').read_bytes()))
    vertices=np.array(base['vertices']).reshape(-1,3)
    faces=np.array(base['triangles']).reshape(-1,3)
    original_domain=shapely.union_all(shapely.polygons(vertices[faces,:2]))
    patches=[]
    # These are specific named flat floors, not a nearest/highest surface pass.
    # Stair risers and treads remain on the continuous tactical ground field.
    for oid,z,label in [(6070,2.,'B Site lower floor'),(6072,4.,'B Site upper floor'),(7353,2.,'Mid flat floor')]:
        obj=objects[oid]
        ids=np.arange(obj['firstFace'],obj['firstFace']+obj['faceCount'])
        triangles=raw['points'][raw['faces'][ids]].astype(float)
        normal=np.cross(triangles[:,1]-triangles[:,0],triangles[:,2]-triangles[:,0])
        length=np.linalg.norm(normal,axis=1)
        keep=(abs(normal[:,2])>.99*length)&(length>1e-10)&(abs(triangles[:,:,2]-z).max(axis=1)<.04)
        assert keep.any()
        domain=shapely.union_all(shapely.polygons(triangles[keep,:,:2])).intersection(original_domain)
        # Source triangle seams can contain sub-nanometre slivers. Only simplify
        # the ground triangulation, never the authored SVG wall footprints.
        before=domain
        domain=domain.simplify(1e-7,preserve_topology=True)
        delta=before.symmetric_difference(domain).area
        assert delta<1e-4
        vertices,faces,report=replace_ground_footprint(vertices,faces,domain,z)
        patches.append(dict(label=label,sourceObject=oid,sourcePath=obj['path'],
            sourceFaces=ids[keep].tolist(),maximumSurfaceDeviationMeters=float(abs(triangles[keep,:,2]-z).max()),
            groundSimplificationAreaMetersSquared=delta,**report))
    # Drop unused vertices left behind by clipping, preserving all used doubles.
    used,inverse=np.unique(faces.reshape(-1),return_inverse=True)
    vertices=vertices[used];faces=inverse.reshape(-1,3)
    result=dict(version=1,map='sunset',coordinateSpace='native-meters',
        vertices=vertices.reshape(-1).tolist(),triangles=faces.reshape(-1).tolist(),
        reviewStatus='reviewed',patches=patches,
        policy='Three inspected flat source floor domains replace false navigation interpolation. Millimetre floor dressing is flattened to the measured nominal floor. Other ground remains unchanged; no wall XY is imported.')
    output=REV/'sunset-reviewed-ground-v1';output.mkdir(exist_ok=True)
    encoded=json.dumps(result,separators=(',',':'),allow_nan=False).encode()
    (output/'sunset.json.gz').write_bytes(gzip.compress(encoded,mtime=0))
    (output/'evidence.json').write_text(json.dumps(dict(vertices=len(vertices),triangles=len(faces),patches=patches),indent=2)+'\n')
    print(json.dumps(dict(vertices=len(vertices),triangles=len(faces),gzipBytes=len(gzip.compress(encoded,mtime=0)),patches=[{k:v for k,v in p.items() if k!='sourceFaces'} for p in patches])))


if __name__=='__main__':main()

"""Sample explicit support domains against their selected source meshes."""
import argparse
import json
from pathlib import Path

import numpy as np
import shapely

from audit_svg_source_height_associations import ROOT
from compile_reviewed_svg_height_map import polygon


def selected_surface_triangles(archive, objects, support):
    ids = support.get('sourceObjects', support.get('selectedSourceObjects', []))
    selected = support.get('sourceTopFaces')
    if selected is not None:
        if not selected or any(not isinstance(i, int) for i in selected):
            raise ValueError('Selected support faces must be nonempty integer IDs')
        ranges = [(objects[oid]['firstFace'],
                   objects[oid]['firstFace'] + objects[oid]['faceCount']) for oid in ids]
        if any(not any(start <= face < end for start, end in ranges) for face in selected):
            raise ValueError('Selected support face does not belong to its source objects')
        triangles = archive['points'][archive['faces'][selected]].astype(float)
    else:
        triangles = np.concatenate([
            archive['points'][archive['faces'][objects[oid]['firstFace']:
                objects[oid]['firstFace'] + objects[oid]['faceCount']]] for oid in ids
        ]).astype(float)
    normal = np.cross(triangles[:, 1] - triangles[:, 0], triangles[:, 2] - triangles[:, 0])
    length = np.linalg.norm(normal, axis=1)
    return triangles[(abs(normal[:, 2]) > .65 * length) & (length > 1e-10)]


def audit(name,path,output):
    decisions=json.loads(path.read_text()); source=ROOT/f'supplemented-v2/world/{name}/geometry.npz'
    archive=np.load(source);objects=json.loads(source.with_suffix('.json').read_text())['objects']
    matrix=np.array(json.loads((ROOT/f'tactical-alignment-sides-v1/{name}.json').read_text())['nativeToAttackSvg'])
    inverse=np.linalg.inv(matrix[:,:2]);cache={};records=[]
    for support in decisions['supports']:
        domain=polygon(support); bounds=domain.bounds
        samples=[domain.representative_point()]
        for x in np.linspace(bounds[0],bounds[2],11)[1:-1]:
            for y in np.linspace(bounds[1],bounds[3],11)[1:-1]:
                point=shapely.Point(x,y)
                if domain.contains(point):samples.append(point)
        ids=support.get('sourceObjects',support.get('selectedSourceObjects',[]))
        oid_key=(tuple(ids),tuple(support.get('sourceTopFaces',[])))
        if oid_key not in cache:
            # A named lower platform can share an object with an overhead beam.
            # Audit its declared faces when supplied, rather than substituting
            # the highest horizontal surface anywhere in that object.
            triangles=selected_surface_triangles(archive,objects,support)
            tree=shapely.STRtree(shapely.polygons(triangles[:,:,:2]))
            planes=np.linalg.solve(np.concatenate([triangles[:,:,:2],np.ones((len(triangles),3,1))],axis=2),triangles[:,:,2,None])[:,:,0]
            cache[oid_key]=(tree,planes)
        tree,planes=cache[oid_key];hits=[];missing=0;failed=[]
        for p in samples:
            native=inverse@(np.array(p.coords)[0]-matrix[:,2]);matches=tree.query(shapely.Point(native),predicate='intersects')
            if not len(matches):missing+=1;continue
            z=float(np.max(planes[matches,:2]@native+planes[matches,2]));hits.append(z)
            if abs(z-support['surfaceElevationMeters'])>.12:failed.append(dict(svg=[p.x,p.y],actualSourceZ=z))
        records.append(dict(id=support['id'],samples=len(samples),hits=len(hits),missing=missing,
            expectedZ=support['surfaceElevationMeters'],minimumSourceZ=min(hits,default=None),maximumSourceZ=max(hits,default=None),
            mismatches=failed))
    output.write_text(json.dumps(dict(map=name,scope='Interior grid against declared source faces when provided, otherwise highest horizontal triangles in selected objects. Absent coverage and mixed heights require review.',supports=records),indent=2)+'\n')
    print(json.dumps(records))


if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--map',required=True);p.add_argument('--decisions',required=True,type=Path);p.add_argument('--out',required=True,type=Path);a=p.parse_args();audit(a.map,a.decisions,a.out)

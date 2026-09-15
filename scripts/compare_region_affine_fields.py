"""Compare two piecewise affine source fields on their exact overlay vertices."""
import json,sys
import numpy as np
import shapely
from authored_region_cells import barycentric

def compare(old,new):
    s0=np.array(old['sourceVerticesSvg']);t0=np.array(old['targetVerticesSvg']);c0=np.array(old['triangles'])
    s1=np.array(new['sourceVerticesSvg']);t1=np.array(new['targetVerticesSvg']);c1=np.array(new['triangles'])
    polygons=shapely.polygons(s0[c0]);tree=shapely.STRtree(polygons);maximum=0.;count=0;where=None
    for j,poly in enumerate(shapely.polygons(s1[c1])):
        for i in tree.query(poly,predicate='intersects'):
            intersection=shapely.intersection(poly,polygons[i]);points=shapely.get_coordinates(intersection)
            if not len(points):continue
            a=barycentric(points,s0[c0[i]])@t0[c0[i]];b=barycentric(points,s1[c1[j]])@t1[c1[j]]
            error=np.linalg.norm(a-b,axis=1);count+=len(points)
            if error.max()>maximum:maximum=float(error.max());where=dict(point=points[error.argmax()].tolist(),oldCell=int(i),newCell=j)
    return dict(overlayVertices=count,maximumMappingDifferenceSvg=maximum,maximumLocation=where)

if __name__=='__main__':
    from pathlib import Path
    a,b,out=map(Path,sys.argv[1:]);result=compare(json.loads(a.read_text()),json.loads(b.read_text()));out.write_text(json.dumps(result,indent=2));print(result)

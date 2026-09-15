"""Proposal-only continuous source field for the legacy 103/104/105 junction.

The finite region replaces the old arbitrary x=285 clipping frontier. It is
not a cumulative pack builder and does not change any current candidate.
"""
import gzip
import hashlib
import json
from pathlib import Path

import numpy as np
import shapely

from authored_region_cells import barycentric
from tactical_alignment_composite import explicit_warp
from verify_region_mapping import verify_region_topology

ROOT = Path('E:/IcarusWorldAudit/2026-09-06')
REV = ROOT/'tactical-visibility-revision'


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def declaration():
    wp = REV/'display-warps-v1/split.display-warp.json.gz'
    w = json.loads(gzip.decompress(wp.read_bytes()))
    matrix = np.column_stack((w['projection']['axisU'], w['projection']['axisV']))
    origin = np.array(w['projection']['origin'])
    ws = np.array(w['sourceNativeMeters']).reshape(-1,2)@matrix.T+origin
    wt = np.array(w['targetAttackSvg']).reshape(-1,2)
    wc = np.array(w['triangles']).reshape(-1,3)
    forward = explicit_warp(ws, wt-ws, wc)
    polygons = shapely.polygons(ws[wc]); tree = shapely.STRtree(polygons)
    binding = REV/'split-wall-family-normalized-candidate-v29/bindings.json'
    prior = json.loads(binding.read_text())
    old106 = next(f for f in prior['families'] if f['edge']==106)
    left = 291.0197140465251
    def along106(x):
        a,b=old106['sourceAlong']; c,d=old106['targetAlong']
        return c+(x-a)/(b-a)*(d-c)
    xs = [267.,274.,279.28622987276356,279.38096371,285.,
          290.78207409,left,292.5927999,293.04229348134476,300.93133,
          314.51621214924637,320.,330.,345.,371.1813963034822,381.14,390.]
    ys = [262.,274.09398997,279.49619023,280.8797487438403,
          282.57213183,288.6989892960074,300.3814600719633,304.33747040034166,311.,
          312.1567706085799,314.5,320.,327.7951324007719,327.7951398577808,335.,345.]
    x_upper = [267.,274.,279.074,279.074,285.572,
               292.365,292.365,292.365,292.365,
               along106(xs[9]),along106(xs[10]),320.,330.,345.,371.1813963034822,381.14,390.]
    x_lower = [267.,274.,279.074,279.074,285.572,
               292.365,292.365,along106(xs[7]),along106(xs[8]),
               along106(xs[9]),along106(xs[10]),320.,330.,345.,371.1813963034822,381.14,390.]
    y_target = [262.,274.09398997,281.157,281.157,281.157,
                288.068,299.631,304.549,310.928,310.928,310.928,
                320.,327.94,327.94,335.,345.]
    source=[]; target=[]; nx=len(xs)
    for row,y in enumerate(ys):
        transition=float(np.clip((y-300.3814600719633)/(311.-300.3814600719633),0,1))
        for col,x in enumerate(xs):
            p=np.array([x,y]); source.append(p)
            tx=(1-transition)*x_upper[col]+transition*x_lower[col]
            if y>=320.:
                tx=279.074 if col in [2,3] and y<=327.7951398577808 else x
            q=np.array([tx,y_target[row]])
            if row in [0,len(ys)-1] or col in [0,len(xs)-1]:
                q=forward.apply(p[None])[0]
            target.append(q)
    source=np.array(source);target=np.array(target)
    initial=[]
    for row in range(len(ys)-1):
        for col in range(nx-1):
            a=row*nx+col;b=a+1;c=a+nx;d=c+1
            initial.extend([[a,b,d],[a,d,c]])
    # Outer-boundary identity is literal display W, including every W kink.
    bounds=[xs[0],ys[0],xs[-1],ys[-1]]
    outer=shapely.box(*bounds).boundary
    vertices=[];mapped=[];cells=[];lookup={}
    def add(p,q,constant_axes):
        key=tuple(float(v) for v in p)
        if key in lookup:
            i=lookup[key]
            assert np.linalg.norm(mapped[i]-q)<1e-9
            for axis in constant_axes:mapped[i][axis]=q[axis]
            return i
        i=len(vertices);lookup[key]=i;vertices.append(p);mapped.append(q);return i
    for ids in initial:
        tri=source[ids]; values=target[ids]; polygon=shapely.Polygon(tri)
        for index in tree.query(polygon,predicate='intersects'):
            for part in shapely.get_parts(shapely.intersection(polygon,polygons[index])):
                if not isinstance(part,shapely.Polygon) or part.area==0:continue
                for piece in shapely.get_parts(shapely.constrained_delaunay_triangles(part)):
                    p=np.array(piece.exterior.coords)[:3]
                    q=barycentric(p,tri)@values
                    for axis in range(2):
                        if np.all(values[:,axis]==values[0,axis]):q[:,axis]=values[0,axis]
                    boundary=shapely.distance(shapely.points(p),outer)<1e-10
                    q[boundary]=forward.apply(p[boundary])
                    constant_axes=[axis for axis in range(2) if np.all(values[:,axis]==values[0,axis])]
                    cell=[add(a,b,constant_axes) for a,b in zip(p,q)]
                    if len(set(cell))==3:cells.append(cell)
    meta_path=ROOT/'supplemented-v2/world/split/geometry.json'
    meta=json.loads(meta_path.read_text()); objects=[7898,7700,4540,7864,7866,7896,7899]
    face_ids=[]
    for i in objects:
        obj=meta['objects'][i];face_ids.extend(range(obj['firstFace'],obj['firstFace']+obj['faceCount']))
    family=dict(edge=200105,mappingType='piecewise-affine-region-v1',
        sourceVerticesSvg=np.array(vertices).tolist(),targetVerticesSvg=np.array(mapped).tolist(),
        triangles=cells,box=bounds,identityOuterBoundary=True,
        objects=objects,reviewedSourceFaces=sorted(face_ids),
        reviewedAuthoredSpans=[dict(legacyStraightEdgeIndex=e,completeSpan=e+3,startSvg=a,endSvg=b)
            for e,a,b in [(103,[279.074,288.068],[279.074,281.157]),
                          (104,[279.074,281.157],[292.365,281.157]),
                          (105,[292.365,281.157],[292.365,310.928])]],
        sourceGeometrySha256=sha(ROOT/'supplemented-v2/world/split/geometry.npz'),
        sourceMetadataSha256=sha(meta_path),displayWarpSha256=sha(wp),
        priorCandidateBindingsSha256=sha(binding),
        neighbor106Contact=dict(sourceSvg=[314.51621214924637,312.1567706085799],
            targetSvg=[along106(314.51621214924637),310.928],absoluteHeightMeters=[1.4965420961380005,5.946089267730713]),
        role='Finite shared field for the existing105 assembly and original source-connected wall/depth continuations. Existing source Z, UV and material decisions remain unchanged. No authored contour extrusion.',
        reviewStatus='Proposal only. Newly discovered7896/7899 ownership and complete nearby-source review require root inspection before a bake.',
        pending=['Validate all near-source mounted objects from the unfiltered66-object inventory.',
                 'Replace current105 ownership and give this region precedence over the7898 portion of106 only after exact neighbor contact proof.',
                 'Source profiles, original-height rays and candidate source partition are still required; topology alone is not acceptance.'])
    return family,forward


if __name__=='__main__':
    out=REV/'split-legacy105-connected-region-proposal-v5'
    out.mkdir(exist_ok=True)
    family,forward=declaration()
    path=out/'region-declaration.json'
    if path.exists():raise FileExistsError(path)
    family['depthSourceFaces']=family['reviewedSourceFaces']
    family['sourcePartitionMethod']='finite-convex-cells-v1'
    family['reviewedAuthoredSpans'].append(dict(completeSpan=144,legacyStraightEdgeIndex=140,startSvg=[279.074,327.94],endSvg=[380.084,327.94],heightScope='Existing source profiles only; upper-height gaps remain.'))
    path.write_text(json.dumps(family,indent=2)+'\n')
    proof=verify_region_topology(family,forward)
    (out/'region-topology-review.json').write_text(json.dumps(proof,indent=2)+'\n')
    print(json.dumps(proof))

    import copy
    bottom=copy.deepcopy(family);bottom['edge']=200140;bottom['objects']=[7897];bottom['box']=[314.5,320.,390.,345.]
    raw=np.load(ROOT/'supplemented-v2/world/split/geometry.npz');points=raw['points'];faces=raw['faces'];meta=json.loads((ROOT/'supplemented-v2/world/split/geometry.json').read_text());obj=meta['objects'][7897]
    ids=np.arange(obj['firstFace'],obj['firstFace']+obj['faceCount']);wp=json.loads(gzip.decompress((REV/'display-warps-v1/split.display-warp.json.gz').read_bytes()));matrix=np.column_stack((wp['projection']['axisU'],wp['projection']['axisV']));origin=np.array(wp['projection']['origin']);xy=points[faces[ids],:2]@matrix.T+origin
    bottom['reviewedSourceFaces']=ids[xy[:,:,1].max(1)>320.].tolist();bottom['depthSourceFaces']=bottom['reviewedSourceFaces'];bottom['reviewedAuthoredSpans']=[family['reviewedAuthoredSpans'][-1]]
    bottom['role']='Only the finite sourceY>=320 portion of the connected7897 bottom wall, caps and declining-height profiles. Its upper portions remain available to existing106/107 owners. Same exact field as200105 at the near-coincident7896/7897 seam.'
    bottom['sharedFieldWith']=200105;bottom['sourcePartitionMethod']='finite-convex-cells-v1';family['sourcePartitionMethod']='finite-convex-cells-v1'
    (out/'bottom-continuation-declaration.json').write_text(json.dumps(bottom,indent=2)+'\n');(out/'combined-declarations.json').write_text(json.dumps([family,bottom],indent=2)+'\n')

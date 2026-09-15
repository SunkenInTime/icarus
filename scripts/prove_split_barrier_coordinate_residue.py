"""Exact coordinate-scale evidence for a captured narrow-cell containment failure."""
import gzip,json,math,hashlib
from collections import Counter
from fractions import Fraction as F
import numpy as np
from build_split_connected_tower import REV
from tactical_alignment_audit import pack
from precise_region_containment import exact_weights


def q(value):return F(float(value))
def encoded(value):return dict(numerator=str(value.numerator),denominator=str(value.denominator),decimal=float(value))
def dot(a,b):return sum(x*y for x,y in zip(a,b))
def upward_sqrt(value):
    assert value>=0
    rounded=float(value)
    assert math.isfinite(rounded), 'Certificate magnitude exceeds finite binary64 bound'
    if value and rounded==0:rounded=math.nextafter(0.,math.inf)
    result=math.sqrt(rounded)
    while q(result)*q(result)<value:result=math.nextafter(result,math.inf)
    return result

def weights_at(point,tri):
    a=[tri[1][k]-tri[0][k] for k in range(2)];b=[tri[2][k]-tri[0][k] for k in range(2)];delta=[point[k]-tri[0][k] for k in range(2)];det=a[0]*b[1]-a[1]*b[0]
    u=(delta[0]*b[1]-delta[1]*b[0])/det;v=(a[0]*delta[1]-a[1]*delta[0])/det
    return [1-u-v,u,v]

def exact_stretch_squared(source,target):
    a=[source[1][k]-source[0][k] for k in range(2)];b=[source[2][k]-source[0][k] for k in range(2)];det=a[0]*b[1]-a[1]*b[0];entries=[]
    for axis in range(2):
        u=target[1][axis]-target[0][axis];v=target[2][axis]-target[0][axis]
        entries.extend([(u*b[1]-v*a[1])/det,(a[0]*v-b[0]*u)/det])
    return sum(x*x for x in entries)

def rectangle_cover(points,cells):
    exact=[[q(x) for x in row] for row in points];lo=[min(v[k] for v in exact) for k in range(2)];hi=[max(v[k] for v in exact) for k in range(2)];directed=Counter();total=F(0)
    for cell in cells:
        ids=list(map(int,cell));a,b,c=[exact[i] for i in ids];area2=(b[0]-a[0])*(c[1]-a[1])-(b[1]-a[1])*(c[0]-a[0]);assert area2!=0
        if area2<0:ids=ids[::-1]
        total+=abs(area2)/2
        directed.update(zip(ids,ids[1:]+ids[:1]))
    boundary=[]
    for (a,b),count in directed.items():
        reverse=directed[(b,a)];assert count==1
        if reverse:assert reverse==1;continue
        assert any(exact[a][k]==exact[b][k] and exact[a][k] in [lo[k],hi[k]] for k in range(2)), 'Unpaired internal source edge'
        boundary.append([a,b])
    rectangle_area=(hi[0]-lo[0])*(hi[1]-lo[1]);assert total==rectangle_area
    return dict(lower=[encoded(v) for v in lo],upper=[encoded(v) for v in hi],exactTriangleArea=encoded(total),exactRectangleArea=encoded(rectangle_area),outerEdges=boundary,proof='Every positively oriented cell edge cancels with its opposite except the rectangle boundary; exact positive triangle area equals rectangle area. Thus the source triangles cover the convex rectangle exactly once and shared target vertex IDs make the field continuous.'),lo,hi

def domain_path(start,end,triangles):
    intervals=[]
    for cell,tri in enumerate(triangles):
        if any(max(start[k],end[k])<min(v[k] for v in tri) or min(start[k],end[k])>max(v[k] for v in tri) for k in range(2)):continue
        left=weights_at(start,tri);right=weights_at(end,tri);lo=F(0);hi=F(1)
        for x,y in zip(left,right):
            delta=y-x
            if delta==0:
                if x<0:lo=F(2);break
            elif delta>0:lo=max(lo,-x/delta)
            else:hi=min(hi,-x/delta)
        if lo<=hi:intervals.append((lo,hi,cell))
    intervals.sort();cursor=F(0)
    for lo,hi,cell in intervals:
        assert lo<=cursor, 'Nearest-cell path escapes declared region domain'
        cursor=max(cursor,hi)
    assert cursor>=1, 'Nearest-cell path escapes declared region domain'
    return [dict(cell=cell,start=encoded(lo),end=encoded(hi)) for lo,hi,cell in intervals]

def main():
    out=REV/'split-barrier-containment-diagnostic-v2';j=json.loads((out/'piece-v4.json').read_text());family_path=REV/'split-barrier-corridor-region-proposal-v4/region-declaration.json';f=json.loads(family_path.read_text())
    _,a=pack(REV/'global-ground-complete-v2/split/split.height.bin.gz');parent=1091249;original=a['vertices'][a['faces'][parent]];bary=np.array(j['part'])[:,3:6]
    w=json.loads(gzip.decompress((REV/'display-warps-v1/split.display-warp.json.gz').read_bytes()));matrix=np.column_stack((w['projection']['axisU'],w['projection']['axisV']));origin=w['projection']['origin']
    cell=j['cells'][0]['id'];source=np.array(f['sourceVerticesSvg']);target=np.array(f['targetVerticesSvg']);cells=np.array(f['triangles']);tri=source[cells[cell]]
    gradients=np.linalg.solve(source[cells][:,1:]-source[cells][:,:1],target[cells][:,1:]-target[cells][:,:1]);stretch=np.linalg.svd(gradients,compute_uv=False)[:,0];local=float(stretch[cell]);maximum=float(stretch.max())
    domain,domain_lo,domain_hi=rectangle_cover(source,cells)
    exact_triangles=[[[q(x) for x in row] for row in triangle] for triangle in source[cells]];exact_targets=[[[q(x) for x in row] for row in triangle] for triangle in target[cells]]
    stretch_squared=[exact_stretch_squared(x,y) for x,y in zip(exact_triangles,exact_targets)];global_squared=max(stretch_squared);maximum=upward_sqrt(global_squared);local=upward_sqrt(stretch_squared[cell]);stretch_sum=math.nextafter(maximum+local,math.inf)
    exact=exact_weights(original,bary,matrix,origin,tri);sqtri=exact_triangles[cell];rows=[]
    for index,weights in enumerate(exact):
        point=[sum(weights[k]*sqtri[k][axis] for k in range(3)) for axis in range(2)]
        assert all(domain_lo[k]<=point[k]<=domain_hi[k] for k in range(2)), 'Exact reconstructed vertex outside source domain'
        choices=[]
        if min(weights)>=0:choices.append((F(0),point))
        for edge in range(3):
            p=sqtri[edge];end=sqtri[(edge+1)%3];d=[end[k]-p[k] for k in range(2)];delta=[point[k]-p[k] for k in range(2)];along=max(F(0),min(F(1),dot(delta,d)/dot(d,d)));nearest=[p[k]+along*d[k] for k in range(2)];offset=[point[k]-nearest[k] for k in range(2)];choices.append((dot(offset,offset),nearest))
        distance2,nearest=min(choices,key=lambda item:item[0]);distance=upward_sqrt(distance2);path=domain_path(nearest,point,exact_triangles);rows.append(dict(vertex=index,exactWeights=[encoded(v) for v in weights],sourcePoint=[encoded(v) for v in point],nearestPoint=[encoded(v) for v in nearest],exactSquaredOutsideDistance=encoded(distance2),outsideDistanceSvg=distance,mappedExtensionDifferenceBoundSvg=math.nextafter(stretch_sum*distance,math.inf) if distance else 0.,domainPath=path))
    report=dict(sourceParent=parent,originalSourceFace=2036209,regionCell=cell,sourceTriangleNative=original.tolist(),sourceBarycentrics=bary.tolist(),projectionMatrix=matrix.tolist(),projectionOrigin=origin,exactConvexDomain=domain,regionDeclarationSha256=hashlib.sha256(family_path.read_bytes()).hexdigest(),sourceCellSvg=tri.tolist(),localMaximumStretch=local,fieldMaximumStretch=maximum,exactLocalFrobeniusSquared=encoded(stretch_squared[cell]),exactFieldMaximumFrobeniusSquared=encoded(global_squared),stretchBoundMethod='Exact rational affine Jacobian Frobenius norm squared; sqrt and sum/product rounded outward' ,rows=rows,maximumOutsideDistanceSvg=max(r['outsideDistanceSvg'] for r in rows),maximumMappedExtensionDifferenceBoundSvg=max(r['mappedExtensionDifferenceBoundSvg'] for r in rows),scope='Exact rational original-native/barycentric/projection reconstruction and exact closest-triangle distance. The field is continuous; assigned affine extension and actual field differ by at most the sum of their Lipschitz constants times this distance. This report does not itself admit a fragment or change a containment gate.')
    (out/'coordinate-scale-proof.json').write_text(json.dumps(report,indent=2));print({k:report[k] for k in ['maximumOutsideDistanceSvg','maximumMappedExtensionDifferenceBoundSvg','fieldMaximumStretch']})

if __name__=='__main__':main()

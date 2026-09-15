"""Opt-in coordinate-scale certificates for ill-conditioned source cells.

The normal barycentric gate is unchanged. This path checks exact original
native/provenance coordinates, an exact source-domain cover, a binary64 storage
interval and a conservative mapped-position bound. It cannot admit rank-one
metadata or display-W partition failures.
"""
from collections import Counter
from fractions import Fraction as F
import hashlib,json,math
import numpy as np


def q(v):return F(float(v))
def encoded(v):return dict(numerator=str(v.numerator),denominator=str(v.denominator),decimal=float(v))
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
    a=[tri[1][k]-tri[0][k] for k in range(2)];b=[tri[2][k]-tri[0][k] for k in range(2)];d=[point[k]-tri[0][k] for k in range(2)];det=a[0]*b[1]-a[1]*b[0]
    assert det!=0
    u=(d[0]*b[1]-d[1]*b[0])/det;v=(a[0]*d[1]-a[1]*d[0])/det
    return [1-u-v,u,v]

def nearest_distance_squared(point,tri,weights):
    if min(weights)>=0:return F(0)
    choices=[]
    for edge in range(3):
        p=tri[edge];end=tri[(edge+1)%3];d=[end[k]-p[k] for k in range(2)];delta=[point[k]-p[k] for k in range(2)];along=max(F(0),min(F(1),dot(delta,d)/dot(d,d)));offset=[point[k]-p[k]-along*d[k] for k in range(2)];choices.append(dot(offset,offset))
    return min(choices)

def stretch_squared(source,target):
    a=[source[1][k]-source[0][k] for k in range(2)];b=[source[2][k]-source[0][k] for k in range(2)];det=a[0]*b[1]-a[1]*b[0];entries=[]
    for axis in range(2):
        u=target[1][axis]-target[0][axis];v=target[2][axis]-target[0][axis]
        entries.extend([(u*b[1]-v*a[1])/det,(a[0]*v-b[0]*u)/det])
    return sum(x*x for x in entries)


class SourceCellCertificate:
    def __init__(self,family):
        policy=family['sourceContainmentArithmeticPolicy']
        assert policy==dict(format='icarus-source-cell-coordinate-certificate-v1',coordinateStorageUlps=1,maximumMappedExtensionErrorSvg=1e-7)
        assert not family.get('declaredRankOneMappings'), 'Scalar rank-one overrides require their own continuity bound'
        self.family=family;self.points=[[q(x) for x in row] for row in family['sourceVerticesSvg']];self.targets=[[q(x) for x in row] for row in family['targetVerticesSvg']];self.cells=family['triangles'];self.source=[[self.points[i] for i in cell] for cell in self.cells];self.target=[[self.targets[i] for i in cell] for cell in self.cells]
        self.lower=[min(v[k] for v in self.points) for k in range(2)];self.upper=[max(v[k] for v in self.points) for k in range(2)];directed=Counter();total=F(0)
        for ids,tri in zip(self.cells,self.source):
            a,b,c=tri;area2=(b[0]-a[0])*(c[1]-a[1])-(b[1]-a[1])*(c[0]-a[0]);assert area2!=0;ids=list(ids) if area2>0 else list(reversed(ids));total+=abs(area2)/2;directed.update(zip(ids,ids[1:]+ids[:1]))
        boundary=[]
        for (a,b),count in directed.items():
            assert count==1
            if directed[(b,a)]:assert directed[(b,a)]==1;continue
            assert any(self.points[a][k]==self.points[b][k] and self.points[a][k] in [self.lower[k],self.upper[k]] for k in range(2)), 'Unpaired interior source edge'
            boundary.append([a,b])
        rectangle=(self.upper[0]-self.lower[0])*(self.upper[1]-self.lower[1]);assert total==rectangle,'Source cells do not cover their rectangle exactly once'
        self.stretch=[stretch_squared(a,b) for a,b in zip(self.source,self.target)];self.maximum=upward_sqrt(max(self.stretch));self.records=[]
        data={key:family[key] for key in ['sourceVerticesSvg','targetVerticesSvg','triangles','sourceContainmentArithmeticPolicy']}
        self.proof=dict(format=policy['format'],family=family['edge'],fieldSha256=hashlib.sha256(json.dumps(data,sort_keys=True,separators=(',',':')).encode()).hexdigest(),sourceCells=len(self.cells),exactRectangleArea=encoded(rectangle),exactPositiveTriangleArea=encoded(total),pairedInternalEdges=True,outerEdges=boundary,exactMaximumFrobeniusSquared=encoded(max(self.stretch)),maximumStretchUpperBound=self.maximum,policy=policy)

    def callback(self,native,matrix,origin,parent):
        native=[[q(x) for x in row] for row in native];matrix=[[q(x) for x in row] for row in matrix];origin=[q(x) for x in origin]
        def certify(part,points,triangles,relevant):
            assert np.array_equal(points,np.array(self.family['sourceVerticesSvg'])) and np.array_equal(triangles,np.array(self.cells))
            positions=[]
            for row in part[:,3:6]:
                b=[q(x) for x in row];xy=[native[0][k]+sum(b[j]*(native[j][k]-native[0][k]) for j in [1,2]) for k in range(2)];point=[dot(matrix[k],xy)+origin[k] for k in range(2)];assert all(self.lower[k]<=point[k]<=self.upper[k] for k in range(2)), 'Exact source point outside certified convex domain';positions.append(point)
            candidates=[]
            for cell in np.flatnonzero(relevant):
                weights=[weights_at(point,self.source[cell]) for point in positions];distances=[nearest_distance_squared(point,self.source[cell],w) for point,w in zip(positions,weights)];candidates.append((max(distances),int(cell),weights,distances))
            _,cell,weights,distances=min(candidates,key=lambda row:row[:2]);rows=[];stretch_sum=math.nextafter(self.maximum+upward_sqrt(self.stretch[cell]),math.inf)
            for point,distance2 in zip(positions,distances):
                storage2=sum(q(math.ulp(float(v)))**2 for v in point)
                assert distance2<=storage2, ('Source escape exceeds one XY binary64 storage interval',parent,cell,float(distance2),float(storage2))
                mapped=math.nextafter(stretch_sum*upward_sqrt(distance2),math.inf) if distance2 else 0.
                assert mapped<1e-7, 'Source-cell extension changes mapped position beyond existing mapping gate'
                rows.append(dict(exactOutsideDistanceSquared=encoded(distance2),exactStorageIntervalSquared=encoded(storage2),outsideDistanceUpperBoundSvg=upward_sqrt(distance2),mappedExtensionDifferenceUpperBoundSvg=mapped))
            record=dict(sourceParent=int(parent),regionCell=cell,sourceBarycentrics=part[:,3:6].tolist(),exactMinimumWeight=encoded(min(x for row in weights for x in row)),vertices=rows)
            self.records.append(record)
            return cell,np.array([[float(x) for x in row] for row in weights])
        certify.exact_source_data=[[dot(matrix[k],native[j][:2])+origin[k] for k in range(2)]+[native[j][2]]+[F(int(i==j)) for i in range(3)] for j in range(3)]
        return certify

"""Read-only rational classification of finite-shadow contact fallbacks.

Exact arithmetic refers to the stored float inputs and declared affine receiver.
Coplanar surfaces sharing the receiver plane require an explicit 2D contact
policy. This classifier does not silently resolve that policy or change meshes.
"""
from fractions import Fraction as F
import numpy as np


def sub(a,b): return [x-y for x,y in zip(a,b)]
def dot(a,b): return sum((x*y for x,y in zip(a,b)),F(0))
def cross(a,b): return [a[1]*b[2]-a[2]*b[1],a[2]*b[0]-a[0]*b[2],a[0]*b[1]-a[1]*b[0]]
def rational(values): return [F(float(x)) for x in values]


def clip(polygon,coefficients):
    if not polygon:return []
    output=[]; previous=polygon[-1]; fp=dot(previous,coefficients[:2])+coefficients[2]
    for current in polygon:
        fc=dot(current,coefficients[:2])+coefficients[2]
        if (fp>=0)!=(fc>=0):
            t=fp/(fp-fc);output.append([a+(b-a)*t for a,b in zip(previous,current)])
        if fc>=0:output.append(current)
        previous,fp=current,fc
    unique=[]
    for row in output:
        if not unique or row!=unique[-1]:unique.append(row)
    if len(unique)>1 and unique[0]==unique[-1]:unique.pop()
    return unique


def classify(eye,triangle,receiver):
    e=rational(eye);t=[rational(row) for row in triangle]
    a,b,c=rational(receiver.floor_plane); height=F(float(receiver.standing_height))
    h=a*e[0]+b*e[1]+c+height-e[2]
    def restrict(normal,offset):
        return [normal[0]+normal[2]*a,normal[1]+normal[2]*b,offset+normal[2]*h]
    n=cross(sub(t[1],t[0]),sub(t[2],t[0]))
    if not any(n):
        # Treat rank-deficient inputs as contact sets. A segment and eye in the
        # receiver plane can cast a two-dimensional wedge despite zero area.
        direction=next((sub(p,t[0]) for p in t[1:] if p!=t[0]),None)
        if direction is None:
            if e==t[0]:
                return dict(kind='source-point-at-eye-needs-origin-contact-policy',filledShadowDimensionUpperBound=2)
            return dict(kind='source-point-away-from-eye',filledShadowDimensionUpperBound=1)
        contact_normal=cross(direction,sub(e,t[0]))
        if not any(contact_normal):
            axis=next(i for i,v in enumerate(direction) if v)
            if min(p[axis] for p in t)<=e[axis]<=max(p[axis] for p in t):
                return dict(kind='source-segment-contains-eye-needs-origin-contact-policy',filledShadowDimensionUpperBound=2)
            return dict(kind='source-segment-collinear-eye',filledShadowDimensionUpperBound=1)
        if not any(restrict(contact_normal,F(0))):
            return dict(kind='source-segment-eye-and-receiver-needs-2d-contact-policy',filledShadowDimensionUpperBound=2)
        return dict(kind='source-segment-distinct-receiver-plane',filledShadowDimensionUpperBound=1)
    distance=dot(n,sub(e,t[0]))
    if distance==0:
        coefficients=restrict(n,F(0))
        if any(coefficients):
            return dict(kind='coplanar-eye-distinct-receiver-plane',filledShadowDimensionUpperBound=1)
        return dict(kind='coplanar-eye-and-receiver-needs-2d-contact-policy',filledShadowDimensionUpperBound=2)
    sign=1 if distance>0 else -1
    planes=[]
    for i in range(3):
        normal=cross(sub(t[i],e),sub(t[(i+1)%3],t[i]))
        planes.append(restrict([-sign*x for x in normal],F(0)))
    planes.append(restrict([-sign*x for x in n],-abs(distance)))
    polygon=[sub(rational(row),e[:2]) for row in receiver.footprint]
    for coefficients in planes:polygon=clip(polygon,coefficients)
    if not polygon:
        return dict(kind='exact-empty-shadow',filledShadowDimensionUpperBound=-1,polygon=[])
    area2=abs(sum((p[0]*q[1]-p[1]*q[0] for p,q in zip(polygon,polygon[1:]+polygon[:1])),F(0)))
    dimension=2 if area2 else 1 if len(set(map(tuple,polygon)))>1 else 0
    floating=np.array([[float(x) for x in row] for row in polygon])
    area=area2/F(2)
    return dict(kind='exact-positive-area-shadow' if area2 else 'exact-point-or-line-shadow',
        filledShadowDimensionUpperBound=dimension,areaSquareMeters=float(area),
        exactAreaNumerator=str(area.numerator),exactAreaDenominator=str(area.denominator),
        polygonRelativeEye=floating.tolist())

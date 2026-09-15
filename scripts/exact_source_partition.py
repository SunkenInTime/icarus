"""Exact stored-float area bounds for a source triangle partition.

No geometry is rounded. Rational pairwise intersection area is an upper bound
on duplicate coverage; area balance supplies a conservative missing-area bound.
"""
from fractions import Fraction
import numpy as np
import shapely


def rational(value):
    return Fraction(*float(value).as_integer_ratio())


def cross(a,b):return a[0]*b[1]-a[1]*b[0]


def subtract(a,b):return (a[0]-b[0],a[1]-b[1])


def signed_area(poly):
    if len(poly)<3:return Fraction(0)
    return sum((cross(a,b) for a,b in zip(poly,poly[1:]+poly[:1])),Fraction(0))/2


def ccw(poly):return poly if signed_area(poly)>=0 else list(reversed(poly))


def intersection(subject,clip):
    # A point-only clipping polygon has no bounding half-planes. Treating its
    # zero edges as inequalities otherwise returns the entire subject and
    # makes a zero-area contact invent pairwise area depending on row order.
    if signed_area(subject)==0 or signed_area(clip)==0:return []
    result=list(subject)
    for a,b in zip(clip,clip[1:]+clip[:1]):
        if not result:break
        d=subtract(b,a);next_poly=[]
        for p,q in zip(result,result[1:]+result[:1]):
            pv=cross(d,subtract(p,a));qv=cross(d,subtract(q,a))
            if pv>=0:next_poly.append(p)
            if (pv>=0)!=(qv>=0):
                u=pv/(pv-qv);next_poly.append((p[0]+u*(q[0]-p[0]),p[1]+u*(q[1]-p[1])))
        result=next_poly
    return result


def bounds(poly):
    if not poly:return None
    return (min(p[0] for p in poly),min(p[1] for p in poly),max(p[0] for p in poly),max(p[1] for p in poly))


def decimal_integer(value):
    """Keep exact proof integers without changing Python's global digit limit."""
    if value.bit_length() <= 2000:
        return str(value)
    sign='-' if value < 0 else ''
    remaining=abs(value);chunks=[]
    while remaining:
        remaining,chunk=divmod(remaining,10**9)
        chunks.append(chunk)
    return sign+str(chunks[-1])+''.join(f'{chunk:09d}' for chunk in reversed(chunks[:-1]))


def encoded(value):return dict(numerator=decimal_integer(value.numerator),denominator=decimal_integer(value.denominator),decimal=float(value))


def candidate_pairs(boxes,spatial_index=True):
    """Outward-rounded boxes only prune pairs; exact bounds still decide."""
    active=[i for i,box in enumerate(boxes) if box is not None]
    if not spatial_index or len(active)<64:
        for index,i in enumerate(active):
            for j in active[:index]:
                yield i,j
        return
    approximate=np.array([[float(x) for x in boxes[i]] for i in active])
    assert np.isfinite(approximate).all()
    approximate[:,:2]=np.nextafter(approximate[:,:2],-np.inf)
    approximate[:,2:]=np.nextafter(approximate[:,2:],np.inf)
    polygons=shapely.box(*approximate.T)
    tree=shapely.STRtree(polygons)
    for index,i in enumerate(active):
        for other in sorted(tree.query(polygons[index]).tolist()):
            if other<index:
                yield i,active[other]


def prove_partition(barycentrics,tolerance=1e-9,spatial_index=True):
    array=np.asarray(barycentrics,dtype=float)
    if array.ndim!=3 or array.shape[1:]!=(3,3) or not np.isfinite(array).all():raise ValueError('Expected finite source barycentric triangles')
    reference=[(Fraction(0),Fraction(0)),(Fraction(1),Fraction(0)),(Fraction(0),Fraction(1))];parts=[];boxes=[];total=Fraction(0);inside=Fraction(0);outside=Fraction(0)
    for triangle in array[:,:,1:]:
        poly=ccw([(rational(p[0]),rational(p[1])) for p in triangle]);area=signed_area(poly);clipped=intersection(poly,reference);covered=signed_area(clipped);total+=area;inside+=covered;outside+=area-covered;parts.append(clipped);boxes.append(bounds(clipped))
    pairwise=Fraction(0);positive_pairs=[];tested=0
    for i,j in candidate_pairs(boxes,spatial_index):
        a,b=boxes[i],boxes[j]
        if a[2]<=b[0] or b[2]<=a[0] or a[3]<=b[1] or b[3]<=a[1]:continue
        tested+=1;area=signed_area(intersection(parts[i],parts[j]));assert area>=0
        if area:pairwise+=area;positive_pairs.append(dict(first=i,second=j,area=encoded(area)))
    missing=max(Fraction(0),Fraction(1,2)-inside+pairwise);limit=rational(tolerance)
    # Pairwise overlap overcounts regions covered three or more times, making
    # this conservative. It cannot conceal duplicate or missing source area.
    passed=2*(missing+outside)<limit and 2*pairwise<limit
    return dict(passed=passed,triangles=len(parts),exactPairTests=tested,sourceArea=encoded(Fraction(1,2)),summedTriangleArea=encoded(total),summedInsideArea=encoded(inside),outsideArea=encoded(outside),pairwiseOverlapUpperBound=encoded(pairwise),missingAreaUpperBound=encoded(missing),relativeSymmetricDifferenceUpperBound=encoded(2*(missing+outside)),relativeOverlapUpperBound=encoded(2*pairwise),nonzeroPairIntersections=positive_pairs,tolerance=tolerance,scope='Exact rationals from every stored binary64 barycentric coordinate; no geometry rounding. Pairwise intersection is a conservative duplicate-area bound, not an exact union-area measurement.')

"""Exact stored-coordinate coverage of a source line through finite map cells."""
from fractions import Fraction

import numpy as np

from verify_region_mapping import verify_rank_one_declarations


def cross(a,b):
    return a[0]*b[1]-a[1]*b[0]


def vector(a,b):
    return [b[i]-a[i] for i in range(2)]


def rational_point(p):
    return [Fraction(float(v)) for v in p]


def exact_line_intervals(family,segment):
    source=np.asarray(family['sourceVerticesSvg']);target=np.asarray(family['targetVerticesSvg']);cells=np.asarray(family['triangles'])
    ranks=verify_rank_one_declarations(family)
    start,end=map(rational_point,segment);direction=vector(start,end)
    assert direction!=[0,0]
    output=[]
    for ci,ids in enumerate(cells):
        tri=[rational_point(p) for p in source[ids]]
        determinant=cross(vector(tri[0],tri[1]),vector(tri[0],tri[2]));assert determinant
        sign=1 if determinant>0 else -1
        low,high=Fraction(0),Fraction(1)
        valid=True
        for a,b in zip(tri,tri[1:]+tri[:1]):
            edge=vector(a,b);value=sign*cross(edge,vector(a,start));slope=sign*cross(edge,direction)
            if slope==0:
                if value<0:valid=False;break
            elif slope>0:low=max(low,-value/slope)
            else:high=min(high,-value/slope)
            if low>high:valid=False;break
        if not valid or low==high:continue
        mapped=[]
        for parameter in [low,high]:
            p=[start[i]+parameter*direction[i] for i in range(2)]
            d=vector(tri[0],p);u=cross(d,vector(tri[0],tri[2]))/determinant;v=cross(vector(tri[0],tri[1]),d)/determinant
            weights=[1-u-v,u,v];assert min(weights)>=0
            if ci in ranks:
                declaration=ranks[ci];a,b=map(rational_point,declaration['endpoints']);values=[Fraction(float(x)) for x in declaration['parameters']]
                along=sum(w*t for w,t in zip(weights,values));q=[a[i]+along*(b[i]-a[i]) for i in range(2)]
            else:
                values=[rational_point(p) for p in target[ids]]
                q=[sum(w*p[i] for w,p in zip(weights,values)) for i in range(2)]
            mapped.append(q)
        output.append(dict(cell=ci,start=low,end=high,mapped=mapped))
    cursor=Fraction(0)
    for row in sorted(output,key=lambda row:(row['start'],row['end'])):
        assert row['start']<=cursor, ('Uncovered exact source interval',str(cursor),str(row['start']))
        cursor=max(cursor,row['end'])
    assert cursor==1,('Uncovered exact source line end',str(cursor))
    return output


def exact_wall_gate(family,segment,authored):
    intervals=exact_line_intervals(family,segment)
    a,b=map(rational_point,authored);direction=vector(a,b);length=float(np.linalg.norm(np.asarray(authored)[1]-np.asarray(authored)[0]));assert length>0
    residual=Fraction(0);along=[]
    for row in intervals:
        for point in row['mapped']:
            delta=vector(a,point);residual=max(residual,abs(cross(direction,delta)))
            along.append(float(sum(x*y for x,y in zip(direction,delta)))/length)
    normal=float(residual)/length
    assert normal<1e-7,('Mapped source line is not on the authored wall',normal)
    return dict(sourceSegmentSvg=segment,authoredSegmentSvg=authored,affineIntervals=len(intervals),
        maximumNormalErrorSvg=normal,mappedAlongRangeSvg=[min(along),max(along)],
        continuousNormalContact=True,sourceCoverage='Exact rational clipping and interval union over stored source coordinates, including all narrow cells.',
        heightScope='A planar field contract for existing finite source profiles. No source height or opening is synthesized.')

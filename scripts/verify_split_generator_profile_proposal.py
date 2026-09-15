"""Source-line/cubic and cover-join checks for the isolated generator proposal."""
import argparse
import gzip
import json
from pathlib import Path

import numpy as np
import shapely

from authored_cubic_segments import chord_bound
from native_compact_wall_profiles import sha
from tactical_alignment_composite import explicit_warp
from tactical_alignment_receiver import receiver_domain
from audit_all_map_wall_span_coverage import authored_spans

REV=Path('E:/IcarusWorldAudit/2026-09-06/tactical-visibility-revision')


def subdivide(controls,t):
    a=controls[:-1]+t*(controls[1:]-controls[:-1])
    b=a[:-1]+t*(a[1:]-a[:-1])
    c=b[0]+t*(b[1]-b[0])
    return np.array([controls[0],a[0],b[0],c]),np.array([c,b[1],a[2],controls[-1]])


def restrict(controls,start,end):
    left,_=subdivide(controls,end)
    if start==0:return left
    _,result=subdivide(left,start/end)
    return result


def parameter_at_x(controls,x):
    if x<=controls[0,0]:return 0.
    if x>=controls[-1,0]:return 1.
    low,high=0.,1.
    for _ in range(60):
        t=(low+high)/2
        a=(1-t)**3*controls[0]+3*(1-t)**2*t*controls[1]+3*(1-t)*t*t*controls[2]+t**3*controls[3]
        if a[0]<x:low=t
        else:high=t
    return (low+high)/2


def map_line(field,a,b):
    a,b=np.asarray(a),np.asarray(b);d=b-a
    line=shapely.LineString([a,b])
    cells=field.tri.tree.query(line)
    pieces=shapely.intersection(line,field.tri.polygons[cells])
    assert shapely.difference(line,shapely.union_all(pieces)).length<1e-8
    points=shapely.get_coordinates(pieces)
    params=np.unique(np.clip((points-a)@d/(d@d),0,1))
    points=a+params[:,None]*d
    return points,field.apply(points)


def main(folder):
    path=folder/'region-declaration.json';f=json.loads(path.read_text());r=f['generatorReview']
    source=np.array(f['sourceVerticesSvg']);target=np.array(f['targetVerticesSvg']);cells=np.array(f['triangles'])
    field=explicit_warp(source,target-source,cells)
    constraints=r['sourceConstraints']
    def coord(obj,axis,approx):
        return next(v['sourceCoordinate'] for v in constraints if v['sourceObject']==obj and v['axis']==axis and v['reviewApproximation']==approx)
    xleft=coord(6577,0,40.06979928);xright=coord(6577,0,77.93181860)
    ylo=coord(6577,1,186.11316);yhi=coord(6577,1,187.02293)
    controls=np.array(r['cubic204']['controls']);tests=[];curves=[]
    authored=next(segment for row,segment in authored_spans(Path('assets/maps/split_map.svg'))
                  if row['span']==204)
    actual_controls=np.array([[v.real,v.imag] for v in [authored.start,authored.control1,authored.control2,authored.end]])
    np.testing.assert_array_equal(controls,actual_controls)
    for tag,y in [('front-source-panel',ylo),('front-source-backing',yhi),('front-band-midpoint',(ylo+yhi)/2)]:
        original,mapped=map_line(field,[xleft,y],[xright,y])
        assert np.diff(mapped[:,0]).min(initial=0)>=-1e-12
        # Repeated plateau coordinates are retained in the line output. Each
        # positive along interval receives its own exact Bezier restriction.
        errors=[];hull=[]
        for a,b in zip(mapped[:-1],mapped[1:]) if tag!='front-band-midpoint' else []:
            if b[0]<=a[0]:continue
            ta,tb=[parameter_at_x(controls,float(x)) for x in [a[0],b[0]]]
            part=restrict(controls,ta,tb)
            errors.extend(np.linalg.norm(np.array([a,b])-part[[0,-1]],axis=1))
            hull.append(chord_bound(part))
        maximum=float(max(hull,default=0));endpoint=float(max(errors,default=0))
        assert maximum<=1e-5 and endpoint<1e-10,(maximum,endpoint)
        geometry=shapely.LineString(mapped)
        same_polyline_error=float(shapely.hausdorff_distance(geometry,curves[0])) if curves else 0.
        assert same_polyline_error<1e-10
        tests.append(dict(tag=tag,sourceEndpoints=original[[0,-1]].tolist(),mappedIntervals=len(mapped)-1,
            maximumDifferenceFromCertifiedFrontPolylineSvg=same_polyline_error,
            maxExactCubicRestrictionHullBoundSvg=maximum,maximumAuthoredEndpointErrorSvg=endpoint))
        curves.append(geometry)
    for a in curves[1:]:assert shapely.hausdorff_distance(a,curves[0])<1e-10
    top=coord(6577,1,169.13159367)
    top_box_x=[coord(6694,0,56.48159458),coord(6694,0,64.30083513)]
    top_box_y=[coord(6694,1,161.59722577),coord(6577,1,169.47408)]
    bottom_y=coord(6693,1,194.79846912)
    lower_x=[coord(6693,0,70.12240266),coord(6693,0,77.94164321)]
    straight=[]
    cases=[('generator202',[xleft,top],[xright,top],[[40.3722,168.983],[77.5863,168.983]]),
           ('generator203',[xleft,top],[xleft,yhi],[[40.3722,168.983],[40.3722,186.527]]),
           ('generator205',[xright,top],[xright,yhi],[[77.5863,168.983],[77.5863,186.527]]),
           ('top-cover-front',[top_box_x[0],top_box_y[0]],[top_box_x[1],top_box_y[0]],[[56.3212,161.54],[63.764,161.54]]),
           ('top-cover-left',[top_box_x[0],top_box_y[0]],[top_box_x[0],top_box_y[1]],[[56.3212,161.54],[56.3212,168.983]]),
           ('top-cover-right',[top_box_x[1],top_box_y[0]],[top_box_x[1],top_box_y[1]],[[63.764,161.54],[63.764,168.983]]),
           ('lower-cover-front',[lower_x[0],bottom_y],[lower_x[1],bottom_y],[[69.6119,194.501],[77.5864,194.501]]),
           ('lower-cover-right',[lower_x[1],187.2],[lower_x[1],bottom_y],[[77.5864,186.527],[77.5864,194.501]])]
    for tag,a,b,expected in cases:
        _,mapped=map_line(field,a,b)
        error=float(shapely.hausdorff_distance(shapely.LineString(mapped),shapely.LineString(expected)))
        assert error<1e-10,(tag,error)
        straight.append(dict(tag=tag,sourceEndpoints=[a,b],targetEndpoints=expected,maximumAuthoredLineErrorSvg=error))
    # Cover endpoints are not rewritten to the generator's endpoint. The
    # short bridge at their rear is compared with the actual painted domain.
    wp=REV/'display-warps-v1/split.display-warp.json.gz';w=json.loads(gzip.decompress(wp.read_bytes()))
    attack_path=Path('assets/maps/split_map.svg');defense_path=Path('assets/maps/split_map_defense.svg')
    attack=receiver_domain(attack_path);defense=receiver_domain(defense_path)
    defense=shapely.transform(defense,lambda xy:np.asarray(w['attackToDefenseSvg']['origin'])-xy)
    packet_path=REV/'split-component8-source-review-v3/full-source-context.npz';p=np.load(packet_path)
    box=p['sourceTrianglesSvgZ'][p['sourceObjectIds']==6693]
    join=[]
    for tag,x,target_x in [('cover-left',coord(6693,0,70.12240266),69.6119),
                           ('cover-right',coord(6693,0,77.94164321),77.5864)]:
        original,mapped=map_line(field,[x,float(box[:,:,1].min())],[x,187.2])
        line=shapely.LineString(mapped)
        # Report literal receiver intersections separately. Boundary contact
        # does not by itself represent exposed interior blocking.
        interior_a=shapely.intersection(line,attack.buffer(-1e-7))
        interior_d=shapely.intersection(line,defense.buffer(-1e-7))
        buried_stroke=shapely.LineString([[target_x,186.527],mapped[0]])
        buried_attack=shapely.intersection(buried_stroke,attack)
        buried_defense=shapely.intersection(buried_stroke,defense)
        join.append(dict(tag=tag,sourceEndpoints=original[[0,-1]].tolist(),mappedPoints=mapped.tolist(),
            intendedAuthoredSideX=target_x,maximumSideXErrorSvg=float(abs(mapped[:,0]-target_x).max()),
            authoredStrokeToMappedJoinLengthSvg=float(buried_stroke.length),
            authoredStrokeToMappedJoinAttackReceiverLengthSvg=float(buried_attack.length),
            authoredStrokeToMappedJoinDefenseReceiverLengthSvg=float(buried_defense.length),
            authoredStrokeJoinOnExactCubicResidualSvg=float(abs(mapped[0,1]-restrict(controls,
                parameter_at_x(controls,target_x),parameter_at_x(controls,target_x))[0,1]))
                if target_x<controls[-1,0] else 0.,
            receiverCurveTessellationToleranceSvg=1e-5,
            attackReceiverIntersectionLengthSvg=float(shapely.intersection(line,attack).length),
            defenseReceiverIntersectionLengthSvg=float(shapely.intersection(line,defense).length),
            attackReceiverInteriorLengthSvg=float(interior_a.length),defenseReceiverInteriorLengthSvg=float(interior_d.length),
            interiorArithmeticCollarSvg=1e-7))
        assert abs(mapped[:,0]-target_x).max()<1e-10
        assert interior_a.length==0 and interior_d.length==0
        # The stored receiver is a separately tessellated cubic, so its tiny
        # endpoint sliver is reported literally. No source line is extended
        # or rounded to make that independent approximation disappear.
        assert buried_attack.length<1e-5 and buried_defense.length<1e-5
    retained=sum(row['retainedFaces'] for row in r['materialAdmission'])
    report=dict(scope=__doc__,declarationSha256=sha(path),scriptSha256=sha(Path(__file__)),
        sourcePacketSha256=sha(packet_path),attackSvgSha256=sha(attack_path),defenseSvgSha256=sha(defense_path),
        cubicSourceBandChecks=tests,orthogonalSourceBandChecks=straight,coverRearJoinChecks=join,retainedFaces=retained,
        excludedOriginalGlassFaces=[i for row in r['materialAdmission'] for i in row['omittedOriginalFaces']],
        materialPolicyChanged=False,sourceHeightPolicyChanged=False,productionMutation=False,
        limitations=['This verifies the declared source field and selected source seams, not generated pack fragments.',
            'No all-observer visibility or rendered cone acceptance.',
            'The receiver interior check has an explicit arithmetic collar; literal intersections are also retained.'])
    (folder/'independent-cubic-cover-contact-review.json').write_text(json.dumps(report,indent=2)+'\n')
    print(json.dumps(report,indent=2))


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('folder',type=Path)
    main(parser.parse_args().folder)

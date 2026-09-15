"""Independently attribute cone termination to painted SVG walls using GEOS."""
import argparse
import gzip
import hashlib
import json
import math
from pathlib import Path
import numpy as np
import shapely
from compile_reviewed_svg_height_map import polygon
from extract_all_map_svg_footprints import extract_map


def prepare(names, output):
    output.mkdir(parents=True, exist_ok=True)
    cases, geometry = [], []
    for name in names:
        for side in ['attack', 'defense']:
            data = json.loads(gzip.decompress(Path(f'assets/maps/{name}_svg_height_{side}.json.gz').read_bytes()))
            svg = Path(f'assets/maps/{name}_map{"_defense" if side == "defense" else ""}.svg')
            extracted, ink, receiver = extract_map(name, side, svg)
            assert not extracted['unsupported']
            shapes = [polygon(w) for w in data['walls']]
            bundled_ink = shapely.union_all(shapes)
            bundled_receiver = shapely.union_all([polygon(r) for r in data['receiver']])
            geometry.append(dict(map=name, side=side, extraWallAreaSvg=bundled_ink.difference(ink).area,
                missingWallAreaSvg=ink.difference(bundled_ink).area,
                receiverDifferenceAreaSvg=receiver.symmetric_difference(bundled_receiver).area))
            points = []
            x0,y0,x1,y1 = receiver.bounds
            for x in np.arange(x0+3, x1, 18):
                for y in np.arange(y0+3, y1, 18):
                    if receiver.contains(shapely.Point(x,y)):
                        for angle in [0., math.pi]: points.append((float(x),float(y),angle,None,'grid'))
            # Near-wall views expose stroke contact errors that distant grids miss.
            for w in extracted['walls']:
                for ring in w['rings']:
                    xy = np.array(ring).reshape(-1,2)
                    for a,b in zip(xy, np.roll(xy,-1,axis=0)):
                        delta=b-a; length=np.linalg.norm(delta)
                        if length<3: continue
                        mid=(a+b)/2; normal=np.array([-delta[1],delta[0]])/length
                        for sign in [-1,1]:
                            p=mid+normal*sign*1.0
                            if receiver.contains(shapely.Point(p)):
                                points.append((*p,math.atan2(mid[1]-p[1],mid[0]-p[0]),None,'wall-contact'))
            for s in data['supports']:
                domain=polygon(s); p=domain.representative_point()
                for angle in [0.,math.pi/2,math.pi,3*math.pi/2]:
                    points.append((p.x,p.y,angle,s['id'],'selected-level'))
            for i,(x,y,a,s,kind) in enumerate(points):
                cases.append(dict(id=f'{name}-{side}-{i}',map=name,side=side,originSvg=[x,y],directionRadians=a,supportId=s,kind=kind))
    (output/'cases.json').write_text(json.dumps(cases,separators=(',',':')))
    (output/'artwork-integrity.json').write_text(json.dumps(geometry,indent=2))
    print(json.dumps(dict(cases=len(cases),geometry=geometry)))


def audit(row, walls, tree, shapes):
    origin=np.array(row['originSvg']); pts=np.array(row['polygonSvg'])[1:]
    a,b=pts[:-1],pts[1:]
    da,db=a-origin,b-origin
    # Ignore the aperture sides and radial shadows cast behind a real corner.
    turn=np.abs(np.arctan2(da[:,0]*db[:,1]-da[:,1]*db[:,0],np.sum(da*db,axis=1)))
    mid=(a+b)/2; distance=np.linalg.norm(mid-origin,axis=1)
    valid=(turn>1e-7)&(distance>1e-8)
    mid,distance,turn=mid[valid],distance[valid],turn[valid]
    direction=(mid-origin)/distance[:,None]
    ends=origin+direction*row['rangeSvg']
    rays=shapely.linestrings(np.stack([np.broadcast_to(origin,ends.shape),ends],axis=1))
    pairs=tree.query(rays,predicate='intersects')
    active=set(row['activeWallIds'])
    keep=np.array([walls[i]['id'] in active for i in pairs[1]],dtype=bool)
    ri,wi=pairs[:,keep]
    intersections=shapely.intersection(rays[ri],shapes[wi])
    distances=shapely.distance(shapely.Point(origin),intersections)
    # GEOS may report a touching candidate whose computed intersection is empty.
    # It contributes no contact; do not let its NaN hide other finite contacts.
    finite=np.isfinite(distances)
    ri,wi,distances=ri[finite],wi[finite],distances[finite]
    expected=np.full(len(rays),float(row['rangeSvg']))
    np.minimum.at(expected,ri,distances)
    # Range-circle chords are a drawing approximation, not a wall contact.
    wall_hit=expected<row['rangeSvg']-1e-5
    error=distance-expected
    arc_sag=row['rangeSvg']*(1-np.cos(turn/2))
    flagged=np.flatnonzero((wall_hit & (abs(error)>.002)) |
        (~wall_hit & (error < -np.maximum(.002,arc_sag+1e-6))))
    issues=[]
    for i in flagged:
        if error[i]<0:
            nearby=tree.query(shapely.Point(mid[i]),predicate='dwithin',distance=.002)
            # At a grazing ray GEOS can miss the exact boundary intersection.
            # A point already on active SVG ink is not an early visual cutoff.
            if any(walls[j]['id'] in active for j in nearby): continue
        candidates=np.flatnonzero((ri==i)&(abs(distances-expected[i])<1e-6))
        wid=walls[wi[candidates[0]]]['id'] if len(candidates) else None
        normal_gap=float(shapely.distance(shapely.Point(mid[i]),shapes[wi[candidates[0]]].boundary)) if len(candidates) else None
        issues.append(dict(actual=mid[i].tolist(),expected=(origin+direction[i]*expected[i]).tolist(),
            errorSvg=float(error[i]),normalGapSvg=normal_gap,wallId=wid,kind='early-clip' if error[i]<0 else 'wall-leak'))
    return len(rays), issues


def run(output, models=None):
    cache={}; issues=[]; rays=0; rows=0
    with (output/'cones.jsonl').open() as source:
        for line in source:
            row=json.loads(line); key=(row['map'],row['side'])
            if key not in cache:
                path = (models / key[0] / f'candidate-{key[1]}.json.gz' if models
                        else Path(f'assets/maps/{key[0]}_svg_height_{key[1]}.json.gz'))
                data=json.loads(gzip.decompress(path.read_bytes()))
                shapes=np.array([polygon(w) for w in data['walls']],dtype=object)
                cache[key]=(data['walls'],shapely.STRtree(shapes),shapes)
            count,found=audit(row,*cache[key]); rays+=count;rows+=1
            if found: issues.append({**row,'issues':found,'maximumErrorSvg':max(abs(x['errorSvg']) for x in found)})
    issues.sort(key=lambda r:-r['maximumErrorSvg'])
    report=dict(cones=rows,checkedIntervals=rays,flaggedCones=len(issues),flaggedIntervals=sum(len(r['issues']) for r in issues),
        conesSha256=hashlib.sha256((output/'cones.jsonl').read_bytes()).hexdigest(),
        thresholdSvg=.002,scope='Independent GEOS ray intersections against active painted footprints. Height semantics require separate source/gameplay review.',cases=issues)
    (output/'boundary-audit.json').write_text(json.dumps(report,separators=(',',':')))
    print(json.dumps({k:v for k,v in report.items() if k!='cases'}))


if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('--output',type=Path,required=True);p.add_argument('--prepare',nargs='+')
    p.add_argument('--models',type=Path);a=p.parse_args()
    prepare(a.prepare,a.output) if a.prepare else run(a.output,a.models)

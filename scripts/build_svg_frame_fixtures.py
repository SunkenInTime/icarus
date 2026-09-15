"""Freeze deterministic moving-cone stress inputs inside each map's SVG floor.

This is a rendering workload, not a gameplay/pathfinding simulation. Every
movement segment stays inside the authored free-floor test domain. Compact
closed cover interiors are excluded from standing observer starts.
"""
import argparse
import hashlib
import json
import math
from pathlib import Path

import numpy as np
import shapely

from audit_svg_source_height_associations import ROOT,REV
from compile_reviewed_svg_height_map import polygon


def build(name,out):
    path=REV/f'all-map-svg-footprints-v1/{name}-attack.json'
    m=json.loads(path.read_text())
    receiver=shapely.union_all([polygon(r) for r in m['receivers']])
    blockers=[]
    for row in m['walls']:
        p=polygon(row)
        if p.convex_hull.area<300:p=p.convex_hull
        blockers.append(p)
    free=receiver.difference(shapely.union_all(blockers).buffer(1.0))
    random=np.random.default_rng(91831+sum(map(ord,name)))
    bounds=np.array(free.bounds);pool=[]
    while len(pool)<1000:
        xy=random.uniform(bounds[:2],bounds[2:])
        if free.contains(shapely.Point(xy)):pool.append(xy)
    pool=np.array(pool);chosen=[0]
    while len(chosen)<10:
        d=np.linalg.norm(pool[:,None,:]-pool[chosen][None,:,:],axis=2).min(axis=1)
        chosen.append(int(d.argmax()))
    positions=pool[chosen].copy();heading=random.uniform(-math.pi,math.pi,10)
    initial=heading.copy()
    matrix=np.array(json.loads((ROOT/f'tactical-alignment-sides-v1/{name}.json').read_text())['nativeToAttackSvg'])
    inverse=np.linalg.inv(matrix[:,:2]);scale=float(np.linalg.norm(matrix[:,0]));step=5.4*scale/144
    frames=[];bounces=0
    for frame in range(420):
        if frame:
            for index in range(10):
                for attempt in range(40):
                    end=positions[index]+step*np.array([math.cos(heading[index]),math.sin(heading[index])])
                    if free.covers(shapely.LineString([positions[index],end])):
                        positions[index]=end;break
                    heading[index]+=random.uniform(.5,2.5);bounces+=1
        directions=initial+np.sin(frame/61+np.arange(10))*.8
        native=(positions-matrix[:,2])@inverse.T
        native_directions=np.c_[np.cos(directions),np.sin(directions)]@inverse.T
        native_directions/=np.linalg.norm(native_directions,axis=1)[:,None]
        poses=[[float(native[i,0]),float(native[i,1]),0.,float(native_directions[i,0]),float(native_directions[i,1]),45.,math.pi/2] for i in range(10)]
        frames.append(dict(frame=frame,positionsSvg=positions.tolist(),directionsSvg=directions.tolist(),poses=poses))
    data=dict(version=1,map=name,agentCount=10,simulatedHz=144,metersToSvg=scale,
              sourceFootprintSha256=hashlib.sha256(path.read_bytes()).hexdigest(),
              workload='Deterministic free-floor movement at 5.4m/s with changing aim. Render stress input, not live game movement or a pathfinding certificate.',
              movementSegmentValidation='Every accepted segment covered by eroded SVG free-floor domain.',
              boundaryDirectionChanges=bounces,frames=frames)
    out.mkdir(parents=True,exist_ok=True);target=out/f'{name}.json'
    target.write_text(json.dumps(data,separators=(',',':'),allow_nan=False)+'\n')
    print(name,len(frames),'frames',flush=True)


if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--maps',nargs='+',required=True);p.add_argument('--out',type=Path,required=True);a=p.parse_args()
    for name in a.maps:build(name,a.out)

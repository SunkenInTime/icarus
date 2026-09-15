"""Compare raised SVG sightlines with independent original-source mesh rays."""
import argparse
from collections import Counter
import json
import math
import numpy as np
import shapely
from audit_all_map_gameplay_levels import MAPS,OUT,ROOT,read
from audit_svg_source_height_associations import EXCLUDED
from compile_reviewed_svg_height_map import polygon
from native_reference_cast import NativeReferenceModel
from audit_icebox_support_sightlines import mesh_hit
from build_all_map_gameplay_supports import support_elevation


def audit(name):
    model=read(OUT/name/'candidate-attack.json.gz')
    folder=OUT.parent/f'full-height-input-v1/{name}'
    source=NativeReferenceModel(folder/f'{name}.height.bin.gz',OUT.parent/'native-tactical-rays-build/Release/tactical_reference_cast.dll')
    mapping=np.load(folder/'source-correspondence.npz')['sourceFaces']
    metadata=read(ROOT/f'supplemented-v2/world/{name}/geometry.json');objects=metadata['objects']
    starts=np.array([o['firstFace'] for o in objects])
    geometry=np.load(ROOT/f'supplemented-v2/world/{name}/geometry.npz')
    ids=np.linspace(0,len(mapping)-1,min(1000,len(mapping)),dtype=int)
    current_pack=np.max(abs(source.arrays['vertices'][source.arrays['faces'][ids]]-geometry['points'][geometry['faces'][mapping[ids]]]))<1e-6
    if current_pack:del geometry
    bounds=np.array([o['boundsMeters'] for o in objects])
    matrix=np.array(read(ROOT/f'tactical-alignment-sides-v1/{name}.json')['nativeToAttackSvg'])
    inverse=np.linalg.inv(matrix[:,:2]);scale=np.linalg.norm(matrix[0,:2])
    shapes=[polygon(w) for w in model['walls']];tree=shapely.STRtree(shapes)
    receiver=shapely.union_all([polygon(r) for r in model['receiver']])
    rows=[];poses=0
    for support in model['supports']:
        if not support.get('automaticStandingAllowed'):continue
        eye=support['surfaceElevationMeters']+model['defaultCameraHeightMeters']
        active=[]
        for wall in model['walls']:
            relative=eye-wall.get('floorElevationMeters',0)
            active.append(wall['unknownHeight'] or any((bottom<=relative and (top is None or relative<=top)) or (bottom==0 and relative<0) for bottom,top in wall['bands']))
        for domain in shapely.get_parts(polygon(support)):
            if domain.geom_type!='Polygon' or domain.area<.1:continue
            point=domain.representative_point();origin=np.array(point.coords)[0]
            eye=support_elevation(support,origin)+model['defaultCameraHeightMeters']
            active=[]
            for wall in model['walls']:
                relative=eye-wall.get('floorElevationMeters',0)
                active.append(wall['unknownHeight'] or any((bottom<=relative and (top is None or relative<=top)) or (bottom==0 and relative<0) for bottom,top in wall['bands']))
            native=(origin-matrix[:,2])@inverse.T;poses+=1
            if not current_pack:
                nearby=(bounds[:,0,2]<=eye)&(bounds[:,1,2]>=eye)&np.all(bounds[:,0,:2]<=native+50/scale,axis=1)&np.all(bounds[:,1,:2]>=native-50/scale,axis=1)
                source_triangles=[]
                for oid in np.flatnonzero(nearby):
                    if any(s in objects[oid]['path'].lower() for s in EXCLUDED):continue
                    obj=objects[oid];tri=geometry['points'][geometry['faces'][obj['firstFace']:obj['firstFace']+obj['faceCount']]]
                    source_triangles.append(tri[(tri[:,:,2].min(1)<=eye)&(tri[:,:,2].max(1)>=eye)])
                source_triangles=np.concatenate(source_triangles)
            for i in range(16):
                angle=i*math.pi/8;direction=np.array([math.cos(angle),math.sin(angle)])
                ray=shapely.LineString([origin,origin+direction*50])
                visible=receiver.intersection(ray)
                segments=[p for p in shapely.get_parts(visible) if p.geom_type=='LineString' and p.distance(point)<1e-7]
                if not segments:continue
                limit=max(float(((np.array(p.coords)-origin)@direction).max()) for p in segments)
                if limit<1:continue
                ray=shapely.LineString([origin,origin+direction*limit])
                first=limit;wid=None
                for wi in tree.query(ray):
                    if not active[wi]:continue
                    hit=shapes[wi].intersection(ray)
                    if not hit.is_empty and point.distance(hit)<first:
                        first=point.distance(hit);wid=model['walls'][wi]['id']
                nd=inverse@direction;nd/=np.linalg.norm(nd)
                excluded=[];hit=None
                for _ in range(64 if current_pack else 0):
                    hit=source.cast(np.r_[native,eye],np.r_[native+nd*limit/scale,eye],excluded_faces=excluded)
                    if hit is None:break
                    oid=int(np.searchsorted(starts,mapping[hit['face']],side='right')-1)
                    if not any(s in objects[oid]['path'].lower() for s in EXCLUDED):break
                    excluded.append(hit['face'])
                distance=limit if hit is None else hit['distanceMeters']*scale
                if not current_pack:
                    distance=mesh_hit(source_triangles,np.r_[native,eye],np.r_[nd,0],limit/scale)*scale
                row=dict(support=support['id'],origin=origin.tolist(),eyeMeters=eye,directionRadians=angle,
                    rangeSvg=limit,svgHit=first,wallId=wid,sourceHit=distance,differenceSvg=distance-first)
                if hit is not None:row.update(sourceObject=oid,sourcePath=objects[oid]['path'],sourceFace=int(mapping[hit['face']]),sourceHitPoint=hit['point'])
                rows.append(row)
    candidates=[r for r in rows if abs(r['differenceSvg'])>3]
    report=dict(map=name,poses=poses,rays=len(rows),materialAlphaResolved=bool(current_pack),candidates=sorted(candidates,key=lambda r:-abs(r['differenceSvg'])),records=rows,
        limitations=['Differences can result from SVG-to-source registration or tactical wall semantics.',
            'These are candidates for source and gameplay review, never automatic wall changes.',
            'Current source packs sample real material alpha. A stale pack uses current raw triangles instead and leaves masked-material interpretation for review.',
            'The SVG still defines every runtime wall position.'])
    (OUT/name/'raised-sightlines.json').write_text(json.dumps(report,indent=2))
    print(json.dumps(dict(map=name,poses=poses,rays=len(rows),falseBlockCandidates=int(sum(r['differenceSvg']>3 for r in candidates)),leakCandidates=int(sum(r['differenceSvg']< -3 for r in candidates)),walls=Counter(r['wallId'] for r in candidates).most_common(8))),flush=True)
    return report


if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('maps',nargs='*',default=MAPS)
    reports=[audit(name) for name in p.parse_args().maps]
    (OUT/'raised-sightline-summary.json').write_text(json.dumps([{k:v for k,v in r.items() if k not in ['records','candidates']} for r in reports],indent=2))

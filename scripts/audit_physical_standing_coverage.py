"""Revisit all earlier floor findings, with explicit physical and data limits."""
from collections import Counter
import argparse
import json
import numpy as np
import shapely
from audit_all_map_gameplay_levels import MAPS, OUT, ROOT, read
from build_all_physical_standing_surfaces import OUTPUT, sha
from build_all_map_gameplay_supports import ground_sampler, support_elevation
from compile_reviewed_svg_height_map import polygon
from gameplay_standing_volumes import StandingVolumes
from gameplay_source_floors import SourceFloors


def audit(name):
    models={s:read(OUTPUT/name/f'candidate-{s}.json.gz') for s in ['attack','defense']}
    model=models['attack'];ground=ground_sampler(model)
    supports=[s for s in model['supports'] if s.get('automaticStandingAllowed')]
    tree=shapely.STRtree([polygon(s) for s in supports])
    receivers={s:shapely.union_all([polygon(r) for r in m['receiver']]) for s,m in models.items()}
    walltrees={s:shapely.STRtree([polygon(w) for w in m['walls']]) for s,m in models.items()}
    alignment=read(ROOT/f'tactical-alignment-sides-v1/{name}.json')
    volumes=StandingVolumes(name);source=SourceFloors(name);rows=[]
    for old in read(OUT/name/'floor-findings.json')['rows']:
        z=old['physicalFloorZ'];xy=old['svg'];p=shapely.Point(xy);g=ground(xy)
        row=dict(nativeXY=old['nativeXY'],originSvg=xy,physicalFloorMeters=z,
            previousStatus=old['status'],collision=old['standingCollision'],sourceObject=old['sourceObject'])
        if old['standingCollision'] is None:
            evidence=source.face(old['sourceObject'],old['sourceFace'])
            row.update(status='render-mesh-'+evidence['classification'],sourceCollision=evidence)
        else:
            matches=[supports[i]['id'] for i in tree.query(p,predicate='intersects')
                if abs(support_elevation(supports[i],xy)-z)<.02]
            if matches:row.update(status='covered-by-physical-standing',supports=matches)
            elif g is not None and abs(g-z)<.02:row['status']='covered-by-ground'
            else:
                excluded=volumes.exclusions(np.asarray(old['nativeXY']),z)
                if excluded:row.update(status='excluded-by-current-player-collision',exclusions=excluded)
                else:
                    walls=[];outside=[]
                    for side,m in models.items():
                        matrix=np.asarray(alignment[f'nativeTo{side.title()}Svg'])
                        point=shapely.Point(matrix[:,:2]@old['nativeXY']+matrix[:,2])
                        if not receivers[side].covers(point):outside.append(side)
                        for i in walltrees[side].query(point,predicate='intersects'):
                            w=m['walls'][i];eye=z+m['defaultCameraHeightMeters']-w['floorElevationMeters']
                            if any(lo<=eye<=hi or lo==0 and eye<0 for lo,hi in w['bands']):
                                walls.append(dict(side=side,wall=w['id']))
                    if outside:row.update(status='outside-displayed-floor',sides=outside)
                    elif walls:row.update(status='inside-active-svg-wall',walls=walls)
                    else:row['status']='unresolved-physical-standing-domain'
        rows.append(row)
    result=dict(map=name,counts=dict(Counter(r['status'] for r in rows)),rows=rows,
        candidateSha256={s:sha(OUTPUT/name/f'candidate-{s}.json.gz') for s in models})
    (OUTPUT/name/'all-prior-floor-coverage.json').write_text(json.dumps(result,separators=(',',':')))
    print(name,result['counts'],flush=True)
    return result


if __name__=='__main__':
    parser=argparse.ArgumentParser();parser.add_argument('maps',nargs='*',default=MAPS)
    names=parser.parse_args().maps
    results=[audit(name) for name in names]
    (OUTPUT/'all-prior-floor-coverage-summary.json').write_text(json.dumps(
        [{k:v for k,v in r.items() if k!='rows'} for r in results],indent=2))

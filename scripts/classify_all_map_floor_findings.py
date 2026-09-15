"""Account for every missing render-floor sample after physical standing audit."""
import argparse
from collections import Counter,defaultdict
import json
import numpy as np
import shapely
from audit_all_map_gameplay_levels import MAPS,OUT,read,planes
from compile_reviewed_svg_height_map import polygon
from gameplay_source_floors import SourceFloors
from build_all_map_gameplay_supports import support_elevation


def classify(name):
    directory=OUT/name
    clearance=read(directory/'standing-clearance.json')
    model=read(directory/'candidate-attack.json.gz')
    eligible=[s for s in model['supports'] if s.get('automaticStandingAllowed')]
    tree=shapely.STRtree([polygon(s) for s in eligible])
    vertices=np.array(model['ground']['vertices']).reshape(-1,3)
    triangles=vertices[np.array(model['ground']['triangles']).reshape(-1,3)]
    ground_tree=shapely.STRtree(shapely.polygons(triangles[:,:,:2]));ground_planes=planes(triangles)
    source=SourceFloors(name);rows=[]
    for r in clearance['samples']:
        if 'sourceMinusGroundMeters' not in r:continue
        row=dict(r)
        z=r['physicalFloorZ'];p=shapely.Point(r['svg'])
        ground_ids=ground_tree.query(p,predicate='intersects')
        ground=None if not len(ground_ids) else float(ground_planes[ground_ids.min(),:2]@r['svg']+ground_planes[ground_ids.min(),2])
        row['previousGroundZ']=r['groundZ'];row['groundZ']=ground
        physical=r['standingCollision'] is not None
        ids=tree.query(p,predicate='intersects')
        matches=[eligible[i]['id'] for i in ids if abs(support_elevation(eligible[i],r['svg'])-z)<=.15]
        if r['exclusions']:
            status='excluded-player-collision'
        elif physical and ground is not None and abs(z-ground)<=.25:
            status='existing-ground-matches-physical-floor'
        elif physical and matches:
            status='covered-by-automatic-standing';row['automaticSupports']=matches
        else:
            if not physical:
                evidence=source.face(r['sourceObject'],r['sourceFace']);row['sourceCollision']=evidence
                status='source-complex-floor-needs-domain' if evidence['physicalFloorConfirmed'] else 'unresolved-physical-floor'
            else:status='physical-floor-needs-domain'
        row['status']=status;rows.append(row)
    groups=defaultdict(list)
    for r in rows:groups[(r['status'],r['sourceObject'])].append(r)
    summaries=[dict(status=status,sourceObject=oid,path=group[0]['sourcePath'],samples=len(group),
        physicalElevationRange=[min(r['physicalFloorZ'] for r in group),max(r['physicalFloorZ'] for r in group)],
        differenceRange=[min(r['physicalFloorZ']-r['groundZ'] for r in group if r['groundZ'] is not None),max(r['physicalFloorZ']-r['groundZ'] for r in group if r['groundZ'] is not None)]) for (status,oid),group in groups.items()]
    report=dict(map=name,counts=dict(Counter(r['status'] for r in rows)),groups=sorted(summaries,key=lambda r:-r['samples']),rows=rows)
    (directory/'floor-findings.json').write_text(json.dumps(report,indent=2))
    print(json.dumps(dict(map=name,counts=report['counts'])),flush=True)
    return report


if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('maps',nargs='*',default=MAPS)
    result=[classify(name) for name in p.parse_args().maps]
    (OUT/'floor-findings-summary.json').write_text(json.dumps([{k:v for k,v in r.items() if k!='rows'} for r in result],indent=2))

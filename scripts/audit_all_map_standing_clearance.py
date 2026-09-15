"""Check original navigation candidates against serialized player collisions."""
import argparse
from collections import Counter
import json
import numpy as np
from audit_all_map_gameplay_levels import MAPS, OUT
from gameplay_standing_volumes import StandingVolumes, load_json


def audit(name):
    volumes = StandingVolumes(name)
    report = load_json(str(OUT / name / 'level-audit.json'))
    rows=[]
    for source in report['samples']:
        xy=np.array(source['nativeXY'])
        floor,contact=volumes.physical_floor(xy,source['sourceZ'])
        errors=volumes.exclusions(xy,floor)
        rows.append(dict(**source,physicalFloorZ=floor,standingCollision=contact,
                         exclusions=errors,eligible=contact is not None and not errors))
    supports=[]
    matrix=np.array(load_json(str(OUT.parent.parent/f'tactical-alignment-sides-v1/{name}.json'))['nativeToAttackSvg'])
    inverse=np.linalg.inv(matrix[:,:2])
    for support in report['supports']:
        checks=[]
        for source in support['rows']:
            xy=(np.array(source['svg'])-matrix[:,2])@inverse.T
            floor,contact=volumes.physical_floor(xy,support['surfaceElevationMeters'])
            errors=volumes.exclusions(xy,floor)
            checks.append(dict(**source,physicalFloorZ=floor,standingCollision=contact,
                exclusions=errors,eligible=bool(source['navMatches']) and contact is not None and not errors))
        supports.append(dict(id=support['id'],label=support['label'],rows=checks,
            existingAutomatic=support['automaticStandingAllowed'],eligibleSamples=sum(r['eligible'] for r in checks),samples=len(checks)))
    result=dict(map=name,volumes=volumes.rows,unresolvedVolumes=volumes.unresolved,samples=rows,supports=supports)
    (OUT/name/'standing-clearance.json').write_text(json.dumps(result,separators=(',',':')))
    summary=dict(map=name,volumes=len(volumes.rows),unresolvedVolumes=len(volumes.unresolved),
        samples=len(rows),eligibleSamples=sum(r['eligible'] for r in rows),
        missingPhysicalFloor=sum(r['standingCollision'] is None for r in rows),
        rejectedReasons=dict(Counter(e['reason'] for r in rows for e in r['exclusions'])),
        fullClearanceSupports=sum(r['samples']==r['eligibleSamples'] for r in supports))
    print(json.dumps(summary),flush=True)
    return summary


if __name__=='__main__':
    parser=argparse.ArgumentParser();parser.add_argument('maps',nargs='*',default=MAPS)
    result=[audit(name) for name in parser.parse_args().maps]
    (OUT/'standing-clearance-summary.json').write_text(json.dumps(result,indent=2))

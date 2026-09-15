"""Independent source-ray and Recast-portal checks for bounded transit regions."""
import argparse
import json
from pathlib import Path
import numpy as np
import shapely
from probe_source_floor_regressions import source_model


def run(revision, name, ray_count):
    path = revision / f'sheet-transit-certificate-v1/{name}.json'
    certificate = json.loads(path.read_text())
    source = source_model(revision, name, True)
    parents = {row['parent']: row for row in certificate['parents']}
    shapes = {key: shapely.from_geojson(row['polygon']) for key, row in parents.items()}
    portals = {}
    for transition in certificate['transitions']:
        portals.setdefault((transition['incomingParent'], transition['outgoingParent']), []).append(shapely.LineString(transition['endpoints']))
    failures, reports = [], []
    rng = np.random.default_rng(152138)
    total_rays = total_portals = 0
    for sheet in certificate['sheets']:
        polygon = shapely.from_geojson(sheet['footprint'])
        ids = sheet['parents']
        topology_failures = []
        for a in ids:
            for b in ids:
                if a >= b:
                    continue
                shared = shapes[a].boundary.intersection(shapes[b].boundary)
                if shared.length <= 1e-8:
                    continue
                for pair in [(a,b),(b,a)]:
                    covered = shapely.union_all(portals.get(pair, []))
                    if shared.difference(covered.buffer(1e-8)).length > 1e-8:
                        topology_failures.append(dict(parents=pair, missingSharedBoundaryMeters=shared.difference(covered.buffer(1e-8)).length))
        failures.extend(topology_failures)
        lo, hi = np.array(polygon.bounds).reshape(2,2)
        samples = []
        attempts = 0
        while len(samples) < ray_count and attempts < ray_count*100:
            attempts += 1
            xy = rng.uniform(lo, hi, (2,2))
            line = shapely.LineString(xy)
            if not polygon.covers(line) or line.length < 1e-6:
                continue
            intervals, events = [], [0.,1.]
            vector = xy[1]-xy[0]
            for parent in ids:
                coordinates = shapely.get_coordinates(line.intersection(shapes[parent]))
                if len(coordinates):
                    t = np.clip((coordinates-xy[0])@vector/(vector@vector),0,1)
                    if t.max()-t.min()>1e-11:
                        intervals.append((float(t.min()),float(t.max()),parent));events.extend((t.min(),t.max()))
            events = np.unique(np.round(events,13))
            previous = None
            ray_failures = []
            crossings = 0
            for start,end in zip(events[:-1],events[1:]):
                midpoint = (start+end)/2
                active = [parent for a,b,parent in intervals if a<=midpoint<=b]
                if len(active)!=1:
                    ray_failures.append(dict(reason='nonunique-interior-parent',active=active));break
                parent=active[0]
                if previous is not None and previous!=parent:
                    crossing=shapely.Point(xy[0]+start*vector)
                    if not any(portal.distance(crossing)<=1e-8 for portal in portals.get((previous,parent),[])):
                        ray_failures.append(dict(reason='crossing-without-native-portal',parents=[previous,parent],point=shapely.get_coordinates(crossing).tolist()))
                    crossings += 1
                plane=np.array(parents[parent]['sourcePlane'])
                endpoints=xy[0]+np.array([start,end])[:,None]*vector
                xyz=np.c_[endpoints,endpoints@plane[:2]+plane[2]+1.75]
                hit=source.cast(*xyz,min_distance=1e-5 if start==0 else 0,end_padding=1e-5 if end==1 else 0)
                if hit is not None:
                    ray_failures.append(dict(reason='source-blocker-inside-certified-empty-parent',parent=parent,hit=hit))
                previous=parent
            if ray_failures:
                failures.append(dict(sheet=sheet['id'],ray=xy.tolist(),failures=ray_failures))
            samples.append(dict(portalCrossings=crossings))
            total_portals += crossings
        total_rays += len(samples)
        reports.append(dict(sheet=sheet['id'],parents=ids,rays=len(samples),portalCrossings=sum(sample['portalCrossings'] for sample in samples),topologyFailures=topology_failures))
    result=dict(scope=__doc__,rays=total_rays,nativePortalCrossings=total_portals,sheets=reports,failures=failures,
                limitation='Bounded sufficient-condition geometry plus sampled source rays; singular corner contacts and arbitrary entries/exits still need explicit native state handling. This does not certify an unqualified union-polygon skip.')
    (path.parent/f'{name}-verification.json').write_text(json.dumps(result,indent=2)+'\n')
    print(total_rays,'source rays',total_portals,'native portal crossings',len(failures),'failures',flush=True)


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('revision',type=Path);parser.add_argument('--map',default='split');parser.add_argument('--rays',type=int,default=100)
    args=parser.parse_args();run(args.revision,args.map,args.rays)

"""Replay reviewed standing selections through the served application endpoint."""
import argparse,json
import urllib.request
from build_reviewed_standing_surfaces import OUTPUT,REVIEW
from build_all_physical_standing_surfaces import sha
from audit_all_map_gameplay_levels import MAPS,read


def verify(url):
    results=[]
    for name in MAPS:
        fixture=read(OUTPUT/name/'production-cases.json')
        for side in ['attack','defense']:
            rows=[r for r in fixture['cases'] if r['side']==side]
            for start in range(0,len(rows),10):
                batch=rows[start:start+10]
                poses=[dict(id=r['id'],origin=r['originSvg'],direction=r['directionRadians'],range=r['rangeSvg'],aperture=r['apertureRadians'],
                    surfaceMode='auto' if r.get('automatic') else 'support' if r.get('supportId') else 'ground',supportId=r.get('supportId')) for r in batch]
                request=urllib.request.Request(url+'/api/query',data=json.dumps(dict(map=name,side=side,cones=poses)).encode(),headers={'Content-Type':'application/json'})
                with urllib.request.urlopen(request,timeout=60) as response:actual=json.load(response)['cones']
                assert len(actual)==len(batch)
                for expected,got in zip(batch,actual):
                    assert got['id']==expected['id'] and got['status']=='ready'
                    assert len(got['polygon'])>=3
                    assert abs(got['eyeMeters']-expected['expectedEyeElevationMeters'])<1e-6,(name,side,expected['id'])
                    if expected.get('supportId'):assert got['resolvedSupportId']==expected['supportId']
                    results.append(dict(map=name,side=side,id=got['id'],eyeMeters=got['eyeMeters'],supportId=got['resolvedSupportId']))
        print(name,len(fixture['cases']),'live queries passed',flush=True)
    report=dict(status='passed',url=url,reviewSha256=sha(REVIEW),queries=len(results),results=results)
    (OUTPUT/'live-standing-verification.json').write_text(json.dumps(report,indent=2))
    print(json.dumps(dict(status='passed',queries=len(results))))


if __name__=='__main__':
    parser=argparse.ArgumentParser();parser.add_argument('--url',default='http://127.0.0.1:8776');args=parser.parse_args();verify(args.url)

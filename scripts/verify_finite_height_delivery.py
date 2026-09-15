"""Verify the rebuilt application, served models, and immutable saved reviews."""
import argparse
import json
from pathlib import Path
import urllib.request
from audit_all_map_gameplay_levels import MAPS, ROOT, read
from resolve_local_svg_wall_profiles import OUTPUT, sha


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--url', default='http://127.0.0.1:8773')
    parser.add_argument('--build', action='store_true')
    args = parser.parse_args()
    review = ROOT / 'tactical-visibility-revision/sightline-review'
    def request(route, data=None):
        req = urllib.request.Request(args.url + route,
            data=json.dumps(data).encode() if data is not None else None,
            headers={'Content-Type':'application/json'})
        with urllib.request.urlopen(req,timeout=60) as response:
            return json.load(response)
    models=[]
    for name in MAPS:
        for side in ['attack','defense']:
            expected=sha(OUTPUT/name/f'candidate-{side}.json.gz')
            asset=Path(f'assets/maps/{name}_svg_height_{side}.json.gz')
            assert sha(asset)==expected
            served=request(f'/api/model?map={name}&side={side}')
            assert served['revision']['modelSha256']==expected,(name,side)
            assert served['revision']['nativeSha256']==sha(review/'icarus_height.dll')
            if args.build:
                built=Path('build/windows/x64/runner/Profile/data/flutter_assets')/asset
                assert sha(built)==expected,(name,side,'built asset')
            models.append(dict(map=name,side=side,sha256=expected))
    reviews=[]
    for rid,expected in [
        ('1788823493671-212d5f8','ce19e0a7b292a75466bf74a1326d8a2fab87739c1ab9784701fa659a7a7bc313'),
        ('1788837450544-1eab447c','930030845b7cfb810dcbfe9f9f189555a153f5757f903ae4102d8f308ee3b673')]:
        path=review/f'reviews/{rid}.json'
        assert sha(path)==expected
        saved=read(path)
        assert request(f'/api/reviews/{rid}')==saved
        result=request('/api/query',{k:saved[k] for k in ['map','side','cones']})
        assert all(r['status']=='ready' for r in result['cones']),rid
        reviews.append(dict(id=rid,sha256=expected,computed=result))
    report=dict(status='passed',url=args.url,builtAssetsVerified=args.build,
        models=models,reviews=reviews)
    if args.build:
        binary=Path('build/windows/x64/runner/Profile/icarus.exe')
        library=binary.with_name('icarus_height.dll')
        assert sha(library)==sha(review/'icarus_height.dll')
        report.update(executableSha256=sha(binary),nativeSha256=sha(library))
    (OUTPUT/('delivery-verification.json' if args.build else 'backend-verification.json')).write_text(json.dumps(report,indent=2))
    print(json.dumps(dict(status='passed',models=len(models),savedReviews=len(reviews),builtAssetsVerified=args.build)))


if __name__=='__main__':
    main()

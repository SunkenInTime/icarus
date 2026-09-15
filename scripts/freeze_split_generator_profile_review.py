"""Freeze original-world-height controls for the generator/cover proposal."""
import argparse
import json
from pathlib import Path
import numpy as np

from native_compact_wall_profiles import sha
from native_reference_cast import NativeReferenceModel

ROOT=Path('E:/IcarusWorldAudit/2026-09-06');REV=ROOT/'tactical-visibility-revision'


def main(folder):
    declaration=folder/'region-declaration.json';family=json.loads(declaration.read_text())
    full=REV/'full-height-input-v1/split/split.height.bin.gz'
    correspondence=full.parent/'source-correspondence.npz'
    raw_parent=np.load(correspondence)['sourceFaces']
    meta_path=ROOT/'supplemented-v2/world/split/geometry.json';meta=json.loads(meta_path.read_text())
    starts=np.array([obj['firstFace'] for obj in meta['objects']])
    projection=ROOT/'tactical-alignment-sides-v1/split.json'
    affine=np.array(json.loads(projection.read_text())['nativeToAttackSvg'])
    inverse=np.linalg.inv(affine[:,:2])
    caster=NativeReferenceModel(full,REV/'native-tactical-rays-build/Release/tactical_reference_cast.dll')
    fixtures=[('north-top-cover', [60.,159.],[60.,172.],4.75),
              ('north-above-top-cover',[60.,159.],[60.,172.],6.25),
              ('south-lower-cover',[74.,197.],[74.,182.],4.75),
              ('south-upper-cover',[74.,197.],[74.,182.],6.25),
              ('south-above-both-covers',[74.,197.],[74.,182.],7.25),
              ('generator-left',[37.,177.],[44.,177.],4.75),
              ('generator-right',[80.,177.],[73.,177.],4.75),
              ('generator-curved-front',[59.,191.],[59.,181.],4.75),
              ('generator-upper-roof-opening',[59.,191.],[59.,168.],11.75),
              ('above-entire-reviewed-assembly',[59.,191.],[59.,168.],12.75)]
    records=[]
    for name,a,b,z in fixtures:
        origin=np.r_[(np.array(a)-affine[:,2])@inverse.T,z]
        end=np.r_[(np.array(b)-affine[:,2])@inverse.T,z]
        hit=caster.cast(origin,end)
        direction=end[:2]-origin[:2];distance=float(np.linalg.norm(direction));direction/=distance
        if hit:
            raw=int(raw_parent[hit['face']]);owner=int(np.searchsorted(starts,raw,side='right')-1)
            hit.update(originalSourceFace=raw,sourceObject=owner,sourceObjectPath=meta['objects'][owner]['path'],
                       belongsToReviewedAssembly=owner in family['objects'])
        records.append(dict(id=name,sourceSvgOrigin=a,sourceSvgTarget=b,originalWorldHeightMeters=z,
            originalWorldQuery=[*origin,*direction,distance,1.7976891295541593],originalWorldTarget=end.tolist(),
            originalFullSceneFirstHit=hit,
            heightSemantics='Explicit original-world source height. No claim of an automatic nav-ground observer.'))
    expected=[6694,6577,6692,6693,6577,6577,6577,6577]
    for record,owner in zip(records,expected):
        assert record['originalFullSceneFirstHit']['sourceObject']==owner,(record['id'],record['originalFullSceneFirstHit'])
    assert not records[-1]['originalFullSceneFirstHit'] or not records[-1]['originalFullSceneFirstHit']['belongsToReviewedAssembly']
    report=dict(declarationSha256=sha(declaration),originalFullSourceSha256=sha(full),
        sourceCorrespondenceSha256=sha(correspondence),sourceMetadataSha256=sha(meta_path),projectionSha256=sha(projection),
        scriptSha256=sha(Path(__file__)),records=records,
        scope='Original source controls only. Candidate source-height and actual renderer comparisons remain required.',
        productionMutation=False)
    (folder/'original-height-regression-fixtures.json').write_text(json.dumps(report,indent=2)+'\n')
    files=['region-declaration.json','proposal-review.json','independent-cubic-cover-contact-review.json',
           'source-neighbors.json','source-height-profile-preview.png','original-height-regression-fixtures.json']
    (folder/'frozen-review-index.json').write_text(json.dumps(dict(files=[dict(path=name,sha256=sha(folder/name)) for name in files],
        productionMutation=False,status='Awaiting parent source/preview review before any cumulative bake.'),indent=2)+'\n')
    print(json.dumps([dict(id=r['id'],sourceObject=r['originalFullSceneFirstHit']['sourceObject'] if r['originalFullSceneFirstHit'] else None)
                      for r in records]),flush=True)


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('folder',type=Path)
    main(parser.parse_args().folder)

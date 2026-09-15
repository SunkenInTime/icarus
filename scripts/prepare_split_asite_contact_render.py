"""Four frozen A-site controls, explicit source endpoints and render extension."""
import gzip,json
from pathlib import Path
import numpy as np
from build_global_tactical_candidate import GroundField
from native_compact_wall_profiles import sha
from tactical_alignment_composite import explicit_warp

REV=Path('E:/IcarusWorldAudit/2026-09-06/tactical-visibility-revision')


def main():
    out=REV/'split-asite-v32-render-fixtures-v1';out.mkdir(exist_ok=False)
    source_path=REV/'split-asite-building-standing17-hybrid-v6/first-hit-controls.json';source=json.loads(source_path.read_text())
    config_path=REV/'split-105-v31-render-fixtures-v2/baseline-config.json';config=json.loads(config_path.read_text());cfg=config['maps']['split']
    ground=GroundField(Path(cfg['groundFieldFile']));w=json.loads(gzip.decompress(Path(cfg['displayWarpFile']).read_bytes()))
    native=np.array(w['sourceNativeMeters']).reshape(-1,2);target=np.array(w['targetAttackSvg']).reshape(-1,2);field=explicit_warp(native,target-native,np.array(w['triangles']).reshape(-1,3))
    legacy=np.array(json.loads(Path(cfg['projectionFile']).read_text())['nativeToAttackSvg']);inverse=np.linalg.inv(legacy[:,:2]);mirror=np.array(w['attackToDefenseSvg']['origin'])
    cases=[];queries={};viewports={};records=[]
    for row in source['records']:
        start=np.array(row['queryStart']);end=np.array(row['queryEnd']);delta=end[:2]-start[:2];length=float(np.linalg.norm(delta));direction=delta/length
        literal=np.r_[start,direction,length,1.7976891295541593];render=literal.copy();render[5]+=.2
        floor=float(ground.heights(start[None,:2])[0]);relative=render.copy();relative[2]-=floor
        identifier=f'asite17-{row["originId"]}';origin_svg=field.apply(start[None,:2])[0];saved=(origin_svg-legacy[:,2])@inverse.T;goal=field.apply(end[None,:2])[0]
        case=dict(id=identifier,category='Frozen A-site standing source control; provisional ground renderer',query=[*saved,float(start[2]),*render[3:]],eyeHeightMode='absolute',agentIndex=4,originSvg=origin_svg.tolist(),targetSvg=goal.tolist(),sourceNativeOrigin=start[:2].tolist(),physicalSourceEye=start.tolist(),originalEye=start.tolist(),originalPhysicalQuery=literal.tolist(),renderPhysicalQuery=render.tolist(),literalQueryEnd=end.tolist(),renderRangeExtensionMeters=.2,sourceGroundAtOriginMeters=floor,relativeControlEyeMeters=float(relative[2]),provisionalGroundRelativeRenderQuery=relative.tolist(),authoredSpan='17/18',sourceEvidence=row,expectedAtAuthoredContact='Bounded source17 contact previously confirmed. Cumulative floor-following cones require independent inspection.')
        cases.append(case);queries[identifier]=relative.tolist();records.append(dict(id=identifier,query=literal.tolist(),queryEnd=end.tolist(),sourceEvidence=row))
        center=np.array(row['proposedHybridHit']['displayedHitSvg']);focus=np.r_[center-10,center+10];context=np.array([340.,44.,420.,102.])
        for side in ['attack','defense']:
            def rect(box):return box.tolist() if side=='attack' else np.r_[mirror-box[2:],mirror-box[:2]].tolist()
            viewports[f'{side}/{identifier}']=[dict(name='focus',svgRect=rect(focus)),dict(name='context',svgRect=rect(context))]
    oldfixture=json.loads((REV/'split-105-v31-render-fixtures-v2/split-fixtures.json').read_text())
    fixture=dict(oldfixture,cases=cases,policy='All4 literal horizontal source queries remain in all-source-rays.json. Render queries alone extend range20cm. Original eye and provisional ground-relative eye are explicit; the two ray models remain distinct.')
    cfg['queriesById']=queries;cfg['automaticQueries']=False
    (out/'baseline-config.json').write_text(json.dumps(config,indent=2)+'\n')
    candidate=REV/'split-wall-family-normalized-candidate-v32';pack=candidate/'split.height.bin.gz';cfg['folder']=str(candidate/'native');cfg.pop('candidatePackSha256',None)
    if pack.is_file():cfg['candidatePackSha256']=sha(pack)
    cfg['packBindingStatus']='bound-existing-file' if pack.is_file() else 'pending-candidate-file-do-not-render-until-bound'
    (out/'candidate-config-template.json').write_text(json.dumps(config,indent=2)+'\n')
    (out/'split-fixtures.json').write_text(json.dumps(fixture,indent=2)+'\n');(out/'viewports.json').write_text(json.dumps(dict(cases=viewports),indent=2)+'\n')
    (out/'all-source-rays.json').write_text(json.dumps(dict(sources=[dict(path=str(source_path),sha256=sha(source_path))],records=records),indent=2)+'\n')
    (out/'manifest.json').write_text(json.dumps(dict(sourceEvidenceSha256=sha(source_path),scriptSha256=sha(Path(__file__)),visualCases=4,literalEndpointQueries=4,renderRangeExtensionMeters=.2,groundFile=cfg['groundFieldFile'],groundSha256=sha(Path(cfg['groundFieldFile'])),candidatePack=str(pack),candidatePackSha256=sha(pack) if pack.is_file() else None,productionMutation=False,renderExecuted=False),indent=2)+'\n')
    print(out)


if __name__=='__main__':main()

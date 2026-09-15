"""Freeze eight practical standing poses around the reviewed sewer wall joints."""
import gzip,json
from pathlib import Path
import numpy as np
from build_global_tactical_candidate import GroundField
from tactical_alignment_composite import explicit_warp
from stage_split_v32_contact_candidate import REV, sha


def main():
    out=REV/'split-sewer-v33-render-fixtures-v1';out.mkdir(exist_ok=False)
    config=json.loads((REV/'gallery-105-v31-candidate-v1/candidate-config.json').read_text());cfg=config['maps']['split']
    ground=GroundField(Path(cfg['groundFieldFile']))
    w=json.loads(gzip.decompress(Path(cfg['displayWarpFile']).read_bytes()))
    native=np.array(w['sourceNativeMeters']).reshape(-1,2);target=np.array(w['targetAttackSvg']).reshape(-1,2);cells=np.array(w['triangles']).reshape(-1,3)
    inverse_warp=explicit_warp(target,native-target,cells)
    legacy=np.array(json.loads(Path(cfg['projectionFile']).read_text())['nativeToAttackSvg']);inverse=np.linalg.inv(legacy[:,:2]);mirror=np.array(w['attackToDefenseSvg']['origin'])
    rows=[('north-joint',[364,278],[357.755,273.182]),('north-wall',[364,264],[357.755,264]),
          ('top-return',[350,244],[350,248.196]),('barrier-joint',[334,258],[338.617,258]),
          ('south-joint',[395,316],[389.122,311.46]),('south-wall',[395,324],[389.122,324]),
          ('entrance-upper',[406,293],[397.096,292]),('entrance-lower',[406,300],[397.096,301])]
    cases=[];queries={};viewports={}
    for identifier,shown,goal in rows:
        shown=np.array(shown,dtype=float);goal=np.array(goal,dtype=float)
        physical=inverse_warp.apply(np.array([shown,goal]));start,end=physical
        direction=end-start;length=float(np.linalg.norm(direction));direction/=length
        floor=float(ground.heights(start[None])[0]);absolute=floor+1.75;distance=length+3
        saved=(shown-legacy[:,2])@inverse.T
        queries[identifier]=[*start,1.75,*direction,distance,float(np.deg2rad(103))]
        cases.append(dict(id=identifier,category='Standing sewer joint review; provisional receiver floors',
            query=[*saved,absolute,*direction,distance,float(np.deg2rad(103))],eyeHeightMode='absolute',agentIndex=4,
            originSvg=shown.tolist(),targetSvg=goal.tolist(),sourceNativeOrigin=start.tolist(),
            originalPhysicalQuery=[*start,absolute,*direction,distance,float(np.deg2rad(103))],
            relativeControlEyeMeters=1.75,sourceGroundAtOriginMeters=floor,
            scope='Actual production cone with current standing-floor policy. Source horizontal section checks remain separate.'))
        focus=np.r_[goal-7,goal+7];context=np.r_[np.minimum(shown,goal)-12,np.maximum(shown,goal)+12]
        for side in ['attack','defense']:
            rect=lambda box:box.tolist() if side=='attack' else np.r_[mirror-box[2:],mirror-box[:2]].tolist()
            viewports[f'{side}/{identifier}']=[dict(name='focus',svgRect=rect(focus)),dict(name='context',svgRect=rect(context))]
    prior=json.loads((REV/'split-105-v31-render-fixtures-v2/split-fixtures.json').read_text())
    (out/'split-fixtures.json').write_text(json.dumps(dict(prior,cases=cases,policy='Eight explicit standing poses; no live-game position certification.'),indent=2)+'\n')
    (out/'viewports.json').write_text(json.dumps(dict(cases=viewports),indent=2)+'\n')
    pack=REV/'split-wall-family-normalized-candidate-v32-precise-v1'
    cfg.update(folder=str(pack/'native'),candidatePackSha256=sha(pack/'split.height.bin.gz'),automaticQueries=False,queriesById=queries,samePhysicalPoseAcrossSides=True)
    (out/'baseline-config.json').write_text(json.dumps(config,indent=2)+'\n')
    (out/'manifest.json').write_text(json.dumps(dict(scriptSha256=sha(Path(__file__)),poses=len(cases),sourcePackSha256=cfg['candidatePackSha256'],
        policy='Both sides use identical physical standing poses. V32 remains a provisional comparison baseline.',productionMutation=False),indent=2)+'\n')
    print(json.dumps(dict(output=str(out),poses=len(cases),originalEyes=[r['originalPhysicalQuery'][2] for r in cases])))


if __name__=='__main__':main()

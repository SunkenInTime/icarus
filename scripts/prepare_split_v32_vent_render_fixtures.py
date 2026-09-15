"""Freeze vent source endpoints and an explicit visual subset for V31/V32 replay."""
import gzip,json
from pathlib import Path
import numpy as np
from build_global_tactical_candidate import GroundField
from tactical_alignment_composite import explicit_warp
from lift_reviewed_wall_source_heights import sha

REV=Path('E:/IcarusWorldAudit/2026-09-06/tactical-visibility-revision');out=REV/'split-vent-v32-render-fixtures-v1';out.mkdir(exist_ok=False)
rp=REV/'split-room-upper-chain-standing-rays-v2/composed-rays.json';report=json.loads(rp.read_text());cfgp=REV/'gallery-105-v31-candidate-v1/candidate-config.json';config=json.loads(cfgp.read_text());cfg=config['maps']['split']
ground=GroundField(Path(cfg['groundFieldFile']));w=json.loads(gzip.decompress(Path(cfg['displayWarpFile']).read_bytes()));native=np.array(w['sourceNativeMeters']).reshape(-1,2);target=np.array(w['targetAttackSvg']).reshape(-1,2);forward=explicit_warp(native,target-native,np.array(w['triangles']).reshape(-1,3));mirror=np.array(w['attackToDefenseSvg']['origin'])
legacy=np.array(json.loads(Path(cfg['projectionFile']).read_text())['nativeToAttackSvg']);inverse=np.linalg.inv(legacy[:,:2]);baseline=json.loads((REV/'split-105-v31-render-fixtures-v2/split-fixtures.json').read_text())
selected=[0,2,3,4,5,140,141,153,165,205,215,294,321,337,360,403,415,416,426,486,500,511,516,520,533]
cases=[];records=[];queries={};viewports={}
for i,row in enumerate(report['records']):
    start=np.array(row['originalEye']);end=np.array(row['originalTarget']);delta=end[:2]-start[:2];length=float(np.linalg.norm(delta));heading=delta/length;floor=float(ground.heights(start[None,:2])[0]);query=np.r_[start,heading,length,1.7976891295541593];relative=query.copy();relative[2]-=floor;identifier=f'vent-{i:03d}'
    records.append(dict(id=identifier,sourceRecord=i,sourceEvidence=row,originalPhysicalQuery=query.tolist(),query=relative.tolist(),literalEndpoint=end.tolist(),selectedForRender=i in selected))
    if i not in selected:continue
    rendered=query.copy();rendered[5]+=.2;relative=relative.copy();relative[5]+=.2;shown=forward.apply(start[None,:2])[0];goal=forward.apply(end[None,:2])[0];saved=(shown-legacy[:,2])@inverse.T;center=np.array(row['after']['displaySvg']if row['after']else goal)
    cases.append(dict(id=identifier,category='Frozen source-standing vent contact; provisional ground renderer',query=[*saved,float(start[2]),*rendered[3:]],
        eyeHeightMode='absolute',agentIndex=4,originSvg=shown.tolist(),targetSvg=goal.tolist(),sourceNativeOrigin=start[:2].tolist(),originalEye=start.tolist(),
        literalPhysicalQuery=query.tolist(),originalPhysicalQuery=rendered.tolist(),renderRangeExtensionMeters=.2,relativeControlEyeMeters=float(relative[2]),
        sourceGroundAtOriginMeters=floor,sourceEvidence=row,expectedAtAuthoredContact='Source first-hit evidence is independent of this provisional floor-following cone.'))
    queries[identifier]=relative.tolist();focus=np.r_[center-7,center+7];context=np.r_[np.minimum(shown,center)-12,np.maximum(shown,center)+12]
    for side in ['attack','defense']:
        rect=lambda box:box.tolist()if side=='attack'else np.r_[mirror-box[2:],mirror-box[:2]].tolist()
        viewports[f'{side}/{identifier}']=[dict(name='focus',svgRect=rect(focus)),dict(name='context',svgRect=rect(context))]
fixture=dict(baseline,cases=cases,policy='All534 source endpoints remain frozen separately. The25 explicit contact renders preserve eyes/headings/origins and extend only range20cm; current provisional ground policy applies.')
(out/'split-fixtures.json').write_text(json.dumps(fixture,indent=2)+'\n');(out/'all-source-rays.json').write_text(json.dumps(dict(sourceReportSha256=sha(rp),records=records),indent=2)+'\n');(out/'viewports.json').write_text(json.dumps(dict(cases=viewports),indent=2)+'\n')
cfg.update(automaticQueries=False,queriesById=queries,samePhysicalPoseAcrossSides=True);(out/'baseline-config.json').write_text(json.dumps(config,indent=2)+'\n')
cfg.update(folder=str(REV/'split-wall-family-normalized-candidate-v32-precise-v1/native'),packBindingStatus='Await actual V32 pack; no hash claimed.');cfg.pop('candidatePackSha256',None);(out/'candidate-config-template.json').write_text(json.dumps(config,indent=2)+'\n')
(out/'manifest.json').write_text(json.dumps(dict(sourceReport=stamp if False else str(rp),sourceReportSha256=sha(rp),sourceRays=len(records),visualCases=len(cases),selectedSourceRows=selected,
    selectionReason='Previously reviewed lower173 plane/tip,174 neighborhood,124/125 contacts and cable preservation,175/176 invariants, upper172 middle/return, complete169–171 contacts and mounted panels.',
    scriptSha256=sha(Path(__file__)),renderRangeExtensionMeters=.2,productionMutation=False),indent=2)+'\n');print(json.dumps(dict(output=str(out),sourceRays=len(records),visualCases=len(cases))))

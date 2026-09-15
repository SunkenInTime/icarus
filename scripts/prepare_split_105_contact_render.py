"""Freeze a visual subset of all195 reviewed105 source rays, preserving poses."""
import gzip
import json
from pathlib import Path
import numpy as np
from build_global_tactical_candidate import GroundField
from native_compact_wall_profiles import sha
from tactical_alignment_composite import explicit_warp

REV=Path('E:/IcarusWorldAudit/2026-09-06/tactical-visibility-revision')


def main():
    out=REV/'split-105-v31-render-fixtures-v2';out.mkdir(exist_ok=False)
    config_path=REV/'gallery-pipe-generator-v30-candidate-v1/candidate-config.json';config=json.loads(config_path.read_text());cfg=config['maps']['split']
    ground=GroundField(Path(cfg['groundFieldFile']));w=json.loads(gzip.decompress(Path(cfg['displayWarpFile']).read_bytes()))
    native=np.array(w['sourceNativeMeters']).reshape(-1,2);target=np.array(w['targetAttackSvg']).reshape(-1,2);field=explicit_warp(native,target-native,np.array(w['triangles']).reshape(-1,3))
    legacy=np.array(json.loads(Path(cfg['projectionFile']).read_text())['nativeToAttackSvg']);inverse=np.linalg.inv(legacy[:,:2]);mirror=np.array(w['attackToDefenseSvg']['origin'])
    oldfixture=json.loads((REV/'gallery-pipe-generator-v30-candidate-v1/split-fixtures.json').read_text());cases=[];queries={};viewports={};records=[];sources=[]
    selection={'top':{(278.5,283.),(278.5,287.),(279.2,279.5),(285.7,279.5),(292.2,279.5)},
               'lower':{(288.,307.),(300.,310.95),(300.,327.9),(320.,327.9),(330.,327.9),(300.,335.)}}
    for label,name in [('top','split-legacy105-top-controls-sealed-v7'),('lower','split-legacy105-lower-receiver-review-v7')]:
        path=REV/name/'first-hit-controls.json';source=json.loads(path.read_text());sources.append(dict(path=str(path),sha256=sha(path)))
        for i,row in enumerate(source['records']):
            start=np.array(row['queryStart']);end=np.array(row['queryEnd']);delta=end[:2]-start[:2];length=np.linalg.norm(delta);direction=delta/length
            original=np.r_[start,direction,length,1.7976891295541593];relative=original.copy();relative[2]-=ground.heights(start[None,:2])[0]
            identifier=f'105-{label}-{row["originId"]}-{i:03d}';selected=tuple(row['targetSvg']) in selection[label]
            records.append(dict(id=identifier,sourceRecord=i,group=label,sourceEvidence=row,query=relative.tolist(),selectedForRender=selected))
            if not selected:continue
            # The source truth-table keeps its literal short endpoint. Only
            # rendered contact views extend range20cm so a receiver probe just
            # before a wall cannot masquerade as an early wall stop.
            original=original.copy();original[5]+=.2;relative=relative.copy();relative[5]+=.2
            origin_svg=field.apply(start[None,:2])[0];saved=(origin_svg-legacy[:,2])@inverse.T;goal=field.apply(end[None,:2])[0]
            hit=row['proposedHybridHit'];center=np.array(hit['displayedHitSvg'] if hit else row['targetSvg'])
            # A short target can intentionally stop before the wall. Focus its
            # artwork boundary while retaining the original ray range metadata.
            if label=='lower' and row['targetSvg'][1]==327.9:center=np.array([row['targetSvg'][0],327.94])
            case=dict(id=identifier,category='Frozen105 nav-standing source control; provisional ground renderer',
                query=[*saved,float(start[2]),*original[3:]],eyeHeightMode='absolute',agentIndex=4,
                originSvg=origin_svg.tolist(),targetSvg=goal.tolist(),sourceNativeOrigin=start[:2].tolist(),
                originalPhysicalQuery=original.tolist(),renderRangeExtensionMeters=.2,relativeControlEyeMeters=float(relative[2]),authoredSpan='103/104' if label=='top' else '105/106/140',
                sourceEvidence=row,expectedAtAuthoredContact='Source-directed contact view with20cm range extension. Source table keeps literal endpoints. Floor behavior remains provisional.')
            cases.append(case);queries[identifier]=relative.tolist()
            focus=np.r_[center-10,center+10];context=np.r_[np.minimum(origin_svg,center)-12,np.maximum(origin_svg,center)+12]
            for side in ['attack','defense']:
                def rect(box):
                    if side=='attack':return box.tolist()
                    return np.r_[mirror-box[2:],mirror-box[:2]].tolist()
                viewports[f'{side}/{identifier}']=[dict(name='focus',svgRect=rect(focus)),dict(name='context',svgRect=rect(context))]
    fixture=dict(oldfixture,cases=cases,policy='All195 source rays retain literal endpoints in all-source-rays.json;51 visual controls retain origins/headings/eyes and extend range20cm for wall contact. BothV30/V31 use identical extended rendering queries. Existing provisional ground policy applies.')
    (out/'split-fixtures.json').write_text(json.dumps(fixture,indent=2)+'\n');(out/'viewports.json').write_text(json.dumps(dict(cases=viewports),indent=2)+'\n')
    cfg['queriesById']=queries;cfg['automaticQueries']=False
    (out/'baseline-config.json').write_text(json.dumps(config,indent=2)+'\n')
    (out/'all-source-rays.json').write_text(json.dumps(dict(sources=sources,records=records),indent=2)+'\n')
    (out/'manifest.json').write_text(json.dumps(dict(sourceFiles=sources,sourceConfigSha256=sha(config_path),sourceRays=len(records),visualCases=len(cases),
        scriptSha256=sha(Path(__file__)),renderRangeExtensionMeters=.2,selection={k:[list(v) for v in sorted(values)] for k,values in selection.items()},productionMutation=False),indent=2)+'\n')
    print(json.dumps(dict(folder=str(out),sourceRays=len(records),visualCases=len(cases))))


if __name__=='__main__':main()

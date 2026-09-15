"""Source-bound presentation fixtures for the finite Ascent courtyard candidate."""
import argparse,gzip,json
from pathlib import Path
import numpy as np
import shapely
from prepare_ascent_connected_corners import ROOT,REV
from tactical_alignment_composite import explicit_warp
from tactical_alignment_receiver import receiver_domain
from build_global_tactical_candidate import GroundField
from native_compact_wall_profiles import sha


def run(folder, boat=False):
    folder=Path(folder);out=folder/'render-fixtures';out.mkdir(exist_ok=True)
    binding=json.loads((folder/'bindings.json').read_text());f=binding['families'][0];summary=json.loads((folder/'summary.json').read_text());base=json.loads((REV/'display-all-candidate-config-v1.json').read_text());cfg=dict(base['maps']['ascent']);cfg.update(folder=str(folder/'native'),candidatePackSha256=summary['packSha256'],scopeLabel='Reviewed connected Ascent component5; preserved source-height openings',samePhysicalPoseAcrossSides=True)
    w=json.loads(gzip.decompress(Path(cfg['displayWarpFile']).read_bytes()));matrix=np.column_stack((w['projection']['axisU'],w['projection']['axisV']));origin=np.asarray(w['projection']['origin']);inverse=np.linalg.inv(matrix);raw=np.asarray(w['sourceNativeMeters']).reshape(-1,2)@matrix.T+origin;target=np.asarray(w['targetAttackSvg']).reshape(-1,2);back=explicit_warp(target,raw-target,np.asarray(w['triangles']).reshape(-1,3));legacy=np.asarray(json.loads(Path(cfg['projectionFile']).read_text())['nativeToAttackSvg']);li=np.linalg.inv(legacy[:,:2]);ground=GroundField(Path(cfg['groundFieldFile']));receiver=receiver_domain(Path('assets/maps/ascent_map.svg'));cases=[]
    def add(id,start,aim,height,category,extra):
        points=np.asarray([start,aim]);world=(back.apply(points)-origin)@inverse.T;direction=world[1]-world[0];direction/=np.linalg.norm(direction);legacy_xy=(start-legacy[:,2])@li.T;eye=float(ground.heights(world[:1])[0]+height)
        cases.append(dict(id=id,category=category,query=[*legacy_xy.tolist(),eye,*direction.tolist(),12.,1.7976891295541593],originSvg=start.tolist(),targetSvg=aim.tolist(),agentIndex=8,eyeHeightMode='absolute',sourceNativeOrigin=world[0].tolist(),sourceNativeTarget=world[1].tolist(),relativeControlEyeMeters=height,**extra))
    for span in f['reviewedAuthoredSpans']:
        line=np.asarray([span['startSvg'],span['endSvg']]);tangent=line[1]-line[0];length=np.linalg.norm(tangent);tangent/=length;normal=np.array([-tangent[1],tangent[0]])
        for fraction,label in [(.5,'center'),(min(.2/length,.25),'start-corner'),(max(1-.2/length,.75),'end-corner')]:
            aim=line[0]+fraction*(line[1]-line[0]);starts=[aim+normal*sign*d for d in [6.,4.,2.,1.,.5] for sign in [-1,1] if receiver.covers(shapely.Point(aim+normal*sign*.05)) and receiver.covers(shapely.Point(aim+normal*sign*d))]
            assert starts,(span,label)
            add(f"span-{span['completeSpan']}-{label}",starts[0],aim,1.75,'Source-reviewed connected wall; frozen control standing-height presentation',dict(authoredSpan=span['completeSpan'],boundedTargetLineSvg=line.tolist()))
    if boat:
        original_cases=list(cases)
        for row in original_cases:
            row['finiteFieldTransitionControl']=bool(row['authoredSpan'] in [205,211])
            if row['authoredSpan']!=208:continue
            for height,label in [(2.75,'higher-source-profile'),(4.2,'above-entire-boat-profile')]:
                add(row['id']+'-'+label,np.asarray(row['originSvg']),np.asarray(row['targetSvg']),height,
                    'Explicit source height control; not an inferred standing pose',
                    dict(authoredSpan=208,boundedTargetLineSvg=row['boundedTargetLineSvg'],
                         boatControlHeightMaximumMeters=4.0974222995705105,
                         expectedBoatProfile='clear' if height>4.0974222995705105 else 'preserve-original-height-variation',
                         adjacentSourceWallsMayStillBlock=True))
        cfg['scopeLabel']='Finite connected Ascent boat207–209 and adjoining walls; original Z retained'
        openings=[]
    else:
        profiles=json.loads((folder/'original-source-height-profile-review.json').read_text());openings=[r for r in profiles['rows'] if r['query']['status'] in ['passed-authored-wall','no-candidate-hit']]
    for index,r in enumerate(openings):
        assert r['classification']=='source-profile-gap' and r['nearestDeclaredSourceSectionDistanceSvg']>1e-5
        q=r['query'];add(f'preserved-opening-{index}',np.asarray(q['startSvg']),np.asarray(q['expectedContactSvg']),q['relativeEyeHeightMeters'],'Original source-height opening; later unrelated blockers may remain',dict(authoredSpan=q['completeSpan'],expectedAtAuthoredContact='clear-through-reviewed-profile',sourceSectionClearanceSvg=r['nearestDeclaredSourceSectionDistanceSvg'],sourceEvidence=r['nearestSections']))
    cfg['automaticQueries']=False;cfg['queriesById']={r['id']:[*r['sourceNativeOrigin'],r['relativeControlEyeMeters'],*r['query'][3:]] for r in cases}
    cat=json.loads(Path('assets/maps/world/height_catalog.json').read_text())['maps']['ascent'];fixture=dict(map='ascent',navigationSha256=cat['navigationSha256'],packSha256=cat['packSha256'],policy='Source-profile and displayed wall audit. Query eyes use the existing provisional control ground plus the explicit relative height; these are not live-game standing-floor certification.',cases=cases)
    report=folder/('independent-precise-source-review.json' if boat else 'original-source-height-profile-review.json')
    (out/'ascent-fixtures.json').write_text(json.dumps(fixture,indent=2)+'\n');(out/'candidate-config.json').write_text(json.dumps(dict(scope=cfg['scopeLabel']+'; no production promotion',maps=dict(ascent=cfg)),indent=2)+'\n');(out/'provenance.json').write_text(json.dumps(dict(bindingsSha256=sha(folder/'bindings.json'),sourceProfileReportSha256=sha(report),scriptSha256=sha(Path(__file__)),wallPoses=len(cases)-len(openings),openingControls=len(openings),boatHeightControls=6 if boat else 0),indent=2)+'\n');print(out,len(cases))

if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('candidate');p.add_argument('--boat',action='store_true');args=p.parse_args();run(args.candidate,args.boat)

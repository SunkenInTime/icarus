"""Freeze source-directed standing-profile fixtures for candidate Flutter review."""
import gzip
import json
from pathlib import Path
import numpy as np
import shapely
from audit_all_map_wall_span_coverage import REV,ROOT,sha
from tactical_alignment_composite import explicit_warp
from tactical_alignment_receiver import receiver_domain
from build_global_tactical_candidate import GroundField

def main():
    output=REV/'gallery-reviewed-wall-interiors-v1';output.mkdir(exist_ok=True)
    base=json.loads((REV/'display-all-candidate-config-v1.json').read_text());catalog=json.loads(Path('assets/maps/world/height_catalog.json').read_text())['maps'];config=dict(scope='Three reviewed bounded wall interiors; frozen control standing height. Corners remain unresolved; no all-map acceptance.',maps={});contacts=[]
    for name in ['ascent','icebox']:
        folder=REV/f'{name}-reviewed-wall-candidate-v1';proof=json.loads((folder/'bindings.json').read_text());summary=json.loads((folder/'summary.json').read_text())
        cfg=dict(base['maps'][name]);cfg.update(folder=str(folder/'native'),candidatePackSha256=summary['packSha256'],scopeLabel='Reviewed bounded wall interiors; unchanged provisional ground');config['maps'][name]=cfg
        warp=json.loads(gzip.decompress(Path(cfg['displayWarpFile']).read_bytes()));matrix=np.column_stack((warp['projection']['axisU'],warp['projection']['axisV']));origin=np.array(warp['projection']['origin']);inverse=np.linalg.inv(matrix)
        raw=np.array(warp['sourceNativeMeters']).reshape(-1,2)@matrix.T+origin;target=np.array(warp['targetAttackSvg']).reshape(-1,2);indices=np.array(warp['triangles']).reshape(-1,3);back=explicit_warp(target,raw-target,indices)
        # The fitted native projection matches the legacy app projection within
        # sub-nanometer display precision; the runtime verifies saved apex equality.
        legacy=np.array(json.loads(Path(cfg['projectionFile']).read_text())['nativeToAttackSvg']);legacy_inverse=np.linalg.inv(legacy[:,:2]);ground=GroundField(Path(cfg['groundFieldFile']));receiver=receiver_domain(Path(f'assets/maps/{name}_map.svg'));cases=[]
        for f in proof['families']:
            line=np.full((2,2),f['fixed']);line[:,f['axis']]=f['targetAlong'];axis=(line[1]-line[0])/np.linalg.norm(line[1]-line[0]);normal=np.array([-axis[1],axis[0]]);mid=line.mean(0)
            signs=[sign for sign in [-1,1] if receiver.covers(shapely.Point(mid+normal*sign*.5))];assert len(signs)==1;inward=normal*signs[0]
            inset=.2/np.linalg.norm(line[1]-line[0])
            for t,label in [(.25,'left-interior'),(.5,'center'),(.75,'right-interior'),(inset,'left-transition'),(1-inset,'right-transition')]:
                target_point=line[0]+t*(line[1]-line[0]);start=target_point+inward*6;assert receiver.covers(shapely.Point(start))
                source_xy=(back.apply(np.array([start,target_point]))-origin)@inverse.T;direction=source_xy[1]-source_xy[0];direction/=np.linalg.norm(direction)
                legacy_xy=(start-legacy[:,2])@legacy_inverse.T;eye=float(ground.heights(source_xy[:1])[0]+1.75);case_id=f'wall-{f["edge"]}-{label}'
                query=[*legacy_xy.tolist(),eye,*direction.tolist(),12.,1.7976891295541593]
                row=dict(id=case_id,category='Unresolved normalization endpoint transition' if 'transition' in label else 'Reviewed wall interior; frozen control standing profile, not a live-game pose',query=query,originSvg=start.tolist(),targetSvg=target_point.tolist(),agentIndex=8,eyeHeightMode='absolute',
                    sourceNativeOrigin=source_xy[0].tolist(),sourceNativeTarget=source_xy[1].tolist(),relativeControlEyeMeters=1.75,authoredSpan=f['edge'],boundedTargetLineSvg=line.tolist())
                cases.append(row)
            contacts.append(dict(map=name,edge=f['edge'],legacyStraightEdgeIndex=f['legacyStraightEdgeIndex'],authoredFixedSvg=f['fixed'],boundedTargetLineSvg=line.tolist(),sourceAlong=f['sourceAlong'],targetAlong=f['targetAlong'],axis=f['axis'],
                unresolvedTransitionEndpointsSvg=line.tolist(),sourceBackup=proof['sourceBackup'],candidateFolder=str(folder),bindingsSha256=sha(folder/'bindings.json')))
        fixture=dict(map=name,navigationSha256=catalog[name]['navigationSha256'],packSha256=catalog[name]['packSha256'],policy='Source-directed fixed relative control eye1.75m; absolute source eye is recorded to keep before/after query scope explicit. No live nav-floor certification.',cases=cases)
        fixture_path=output/f'{name}-fixtures.json';backup=output/f'{name}-fixtures-initial-interiors.json'
        if fixture_path.exists() and not backup.exists():backup.write_bytes(fixture_path.read_bytes())
        fixture_path.write_text(json.dumps(fixture,indent=2)+'\n')
    (output/'candidate-config.json').write_text(json.dumps(config,indent=2)+'\n');(output/'contact-spans.json').write_text(json.dumps(contacts,indent=2)+'\n');print(output,flush=True)

if __name__=='__main__':main()

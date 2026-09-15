"""Stage the approved pipe, generator and plank changes over frozen V29 roles."""
import argparse
from copy import deepcopy
import json
from pathlib import Path

from native_compact_wall_profiles import sha
from build_split_normalized_wall_families import main as bake

REV=Path('E:/IcarusWorldAudit/2026-09-06/tactical-visibility-revision')


def stage(version):
    out=REV/f'split-pipe-generator-planks-stage-{version}';out.mkdir(exist_ok=False)
    base_path=REV/'split-wall-family-normalized-candidate-v29/bindings.json'
    base=json.loads(base_path.read_text());families=deepcopy(base['families'])
    paths={200190:REV/'split-pipe130-profile-region-proposal-v5/region-declaration.json',
           200208:REV/'split-generator-connected-profile-proposal-v4/region-declaration.json',
           200123:REV/'split-barrier-planks-source-proposal-v1/region-declaration.json'}
    source_packets=[]
    for edge,path in paths.items():
        declared=json.loads(path.read_text());assert declared['edge']==edge
        family=deepcopy(declared)
        if edge in [200190,200208]:
            assert not family.get('sourceContainmentArithmeticPolicy'), 'Rank-one profiles do not use barrier extension policy'
            family['mappingType']='piecewise-affine-region-v1'
            family['sourcePartitionMethod']='finite-convex-cells-v1'
            family['sourceCoordinateConstruction']='original-native-triangle-v1'
        family['frozenReviewedProposal']=dict(path=str(path),sha256=sha(path),
            compilerOnlyChanges=['mappingType schema name','finite source/W partition method','original-native coordinate construction'] if edge!=200123 else [])
        indices=[i for i,f in enumerate(families) if f['edge']==edge]
        if indices:assert len(indices)==1;families[indices[0]]=family
        else:assert edge==200208;families.append(family)
        source_packets.append(dict(edge=edge,path=str(path),sha256=sha(path)))
    unchanged=[f['edge'] for f in base['families'] if f['edge'] not in paths]
    for edge in unchanged:
        assert next(f for f in families if f['edge']==edge)==next(f for f in base['families'] if f['edge']==edge)
    selected=set(next(f for f in families if f['edge']==200208)['reviewedSourceFaces'])
    overlaps=[]
    for f in families:
        if f['edge']==200208:continue
        other=set(f.get('reviewedSourceFaces',[]))
        if selected&other:overlaps.append(dict(edge=f['edge'],originalSourceFaces=sorted(selected&other)))
    assert not overlaps,overlaps
    declaration=out/'family-declarations.json';declaration.write_text(json.dumps(families,indent=2)+'\n')
    gate=REV/'native-region-source-provenance-gate-v1/summary.json'
    assert gate.exists(),'Original-native actual-source gates must pass before staging'
    helpers=['build_split_normalized_wall_families.py','authored_region_cells.py','authored_wall_profile_cells.py',
        'finite_region_cells.py','native_region_source.py','region_partition_certificate.py','normalization_checkpoint.py']
    manifest=dict(format='icarus-reviewed-cumulative-candidate-stage-v1',version=version,
        baseBindings=dict(path=str(base_path),sha256=sha(base_path)),basePack=dict(path=str(base_path.parent/'split.height.bin.gz'),sha256=sha(base_path.parent/'split.height.bin.gz')),
        reviewedProposals=source_packets,declarationSha256=sha(declaration),unchangedFamilyEdges=unchanged,
        sourceProvenanceGate=dict(path=str(gate),sha256=sha(gate)),
        compilerHelpers=[dict(path=str(Path('scripts')/name),sha256=sha(Path('scripts')/name)) for name in helpers],
        candidateOutput=str(REV/f'split-wall-family-normalized-candidate-{version}'),productionMutation=False,
        sourcePolicy='Rebuild from original control pack using frozen V29 complete roles and only the three approved replacements/additions. Preserve existing source heights, material policy and all unaffected declarations.')
    (out/'stage.json').write_text(json.dumps(manifest,indent=2)+'\n')
    print(json.dumps(dict(stage=str(out),families=len(families),unchangedFamilies=len(unchanged))),flush=True)
    return out


def build(folder):
    manifest=json.loads((folder/'stage.json').read_text());declaration=folder/'family-declarations.json'
    assert sha(declaration)==manifest['declarationSha256']
    for entry in [manifest['baseBindings'],manifest['basePack'],manifest['sourceProvenanceGate'],
                  *manifest['reviewedProposals'],*manifest['compilerHelpers']]:assert sha(entry['path'])==entry['sha256'],entry['path']
    bake(out=Path(manifest['candidateOutput']),frozen_families=json.loads(declaration.read_text()))


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--version',default='v30');parser.add_argument('--bake',action='store_true');parser.add_argument('--staged',type=Path)
    args=parser.parse_args();folder=args.staged or stage(args.version)
    if args.bake:build(folder)

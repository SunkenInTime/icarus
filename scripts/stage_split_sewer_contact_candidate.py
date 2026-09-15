"""Freeze the reviewed sewer joints on the unchanged V32 candidate declarations."""
import argparse
from copy import deepcopy
import json, shutil
from pathlib import Path
import numpy as np
from stage_split_v32_contact_candidate import REV, sha, stamp, read_bound

BASE = REV/'split-wall-family-normalized-candidate-v32-precise-v1'
DECLARATIONS = [
    ('split-sewer108-connected-proposal-v7', '655fcf480da08f6442043e587f0194c1386353ae61715cc6e810619c724ddf5e'),
    ('split-sewer117-simple-proposal-v1', 'ba9b172fb3a230f0cdf2d32ac0bdf308fa9145cd5c1b046cda33229ebc34adc7'),
    ('split-sewer147-return-proposal-v1', '07456ac2be211ac0ad56180a35529a1805b5aa43ec907c74320094171faed44a'),
]
REMOVED_MEMBERS = {108: [6163], 200123: [6166]}
REVIEWED_STORAGE_GUARD = '55f792fcb2d492035f5c93f7edd3ad79df15b9cc33974d69bac7b4606fefab65'


def stage(version,room_declaration=None,room_sha256=None):
    assert version and all(c.isalnum() or c in '-_' for c in version)
    base = read_bound(BASE/'bindings.json', '604d69343a44184440733955f3551b0f090b79e2671c33719215f32de25aab32')
    assert sha(BASE/'split.height.bin.gz') == 'fa631d7415c2cbf90988b50f8a544d5e4afc5e0353e282df4dd41a396fcd648b'
    paths = [REV/name/'region-declaration.json' for name, _ in DECLARATIONS]
    additions = [read_bound(path, expected) for path, (_, expected) in zip(paths, DECLARATIONS)]
    assert [f['edge'] for f in additions] == [200108, 200117, 200147]
    families = deepcopy(base['families'])
    replacements=[];replacement_evidence=[]
    assert (room_declaration is None)==(room_sha256 is None)
    if room_declaration is not None:
        revised=read_bound(room_declaration,room_sha256)
        gate_path=room_declaration.parent/'staging-gate.json'
        gate=read_bound(gate_path,'194ffc92a9d07ad1c94de8aea16fef181e0e00685249546ac37115cb378347da')
        assert gate['passed'] and gate['declaration']['sha256']==room_sha256
        replacement_evidence.append(gate_path)
        for row in [*gate['evidence'],*gate['helpers']]:
            assert sha(row['path'])==row['sha256'];replacement_evidence.append(Path(row['path']))
        index=next(i for i,f in enumerate(families) if f['edge']==200174);old=families[index]
        assert revised['edge']==200174
        for key in ['objects','box','sourceVerticesSvg','triangles','reviewedSourceFaces','sourceCoordinateConstruction','sourcePartitionMethod']:
            assert revised[key]==old[key],('Room source changed',key)
        assert np.array_equal(np.array(revised['targetVerticesSvg'])[:,0],np.array(old['targetVerticesSvg'])[:,0])
        families[index]=revised;paths.append(room_declaration)
        replacements.append(dict(edge=200174,declaration=stamp(room_declaration),sourceCellsAndMembershipUnchanged=True,targetXUnchanged=True))
    membership = []
    for family in families:
        removed = REMOVED_MEMBERS.get(family['edge'])
        if removed:
            old = deepcopy(family)
            assert set(removed).issubset(old['objects'])
            family['objects'] = [obj for obj in old['objects'] if obj not in removed]
            assert {**family, 'objects': old['objects']} == old
            membership.append(dict(edge=family['edge'], removedObjects=removed, retainedObjects=family['objects'], fieldUnchanged=True))
    assert next(f for f in families if f['edge']==108)['objects']==[7897,7895]
    assert len(next(f for f in families if f['edge']==200123)['objects'])==15
    for added in additions:
        for prior in families:
            assert not set(added['objects']) & set(prior['objects']), (added['edge'], prior['edge'], 'Unexpected prior ownership')
    families.extend(additions)
    assert len({f['edge'] for f in families})==len(families)
    output=REV/f'split-connected-contact-stage-{version}';output.mkdir(exist_ok=False)
    declared=output/'family-declarations.json';declared.write_text(json.dumps(families,indent=2)+'\n')
    compiler=output/'compiler';compiler.mkdir();compiler_rows=[]
    for source in sorted(Path('scripts').glob('*.py')):
        destination=compiler/source.name;shutil.copyfile(source,destination);compiler_rows.append(stamp(destination))
    prior_compiler=REV/'split-connected-contact-stage-v32-precise-v1/compiler'
    core=[]
    for name in ['build_split_normalized_wall_families.py','finite_region_cells.py','precise_region_containment.py','native_region_source.py','tactical_pack_writer.py','authored_region_cells.py']:
        expected=REVIEWED_STORAGE_GUARD if name=='precise_region_containment.py' else sha(prior_compiler/name)
        assert sha(compiler/name)==expected, ('Unreviewed compiler change since V32',name)
        core.append(dict(file=name,sha256=sha(compiler/name),literalV32Compiler=name!='precise_region_containment.py',
            reviewedChange='Exact source and mapped escape checked against their binary64 XY storage intervals; no geometry or weight change.' if name=='precise_region_containment.py' else None))
    fixture=Path('scripts/fixtures/asite-cell803-storage.json')
    assert sha(fixture)=='e236d825c98cfdcc162d0f4f156fa81425fc1e34831cf2c336de5d353a35cb25'
    (compiler/'fixtures').mkdir()
    for fixture in sorted(Path('scripts/fixtures').glob('*')):
        if not fixture.is_file():continue
        target=compiler/'fixtures'/fixture.name;shutil.copyfile(fixture,target);compiler_rows.append(stamp(target))
    prior_stage=json.loads((prior_compiler.parent/'stage.json').read_text())
    source_gate=BASE/'source-gate-coordinate-storage-v1.json'
    assert sha(source_gate)=='21b9811c8c8f364f85ce658171253748f96467da53a54f0cf6e38286cacbec5c'
    evidence=[source_gate,REV/'split-sewer-endpoint-join-review-v2/report.json',REV/'split-sewer108-source-contacts-v7/report.json',*replacement_evidence]
    manifest=dict(version=version,baseBindings=stamp(BASE/'bindings.json'),basePack=stamp(BASE/'split.height.bin.gz'),
        reviewedDeclarations=[stamp(p) for p in paths],evidenceFiles=[stamp(p) for p in evidence],
        checkedInputs=prior_stage['checkedInputs'],compilerFiles=compiler_rows,coreCompilerPreservation=core,
        declarationFile=str(declared),declarationSha256=sha(declared),
        candidateOutput=str(REV/f'split-wall-family-normalized-candidate-{version}'),
        unchangedFamilyEdges=[f['edge'] for f in base['families'] if f['edge'] not in REMOVED_MEMBERS and f['edge'] not in [r['edge'] for r in replacements]],
        changedFamilyMembership=membership,addedFamilyEdges=[f['edge'] for f in additions],
        replacedFamilyDeclarations=replacements,
        baseReview='V32 full source gate passed with the bound storage guard. Standing-floor/jamb gameplay review remains separate.',
        sourcePolicy='Original source heights, UVs, materials and openings retained. Only reviewed connected source XY fields change.',
        floorPolicy=prior_stage['floorPolicy'],productionMutation=False)
    (output/'stage.json').write_text(json.dumps(manifest,indent=2)+'\n')
    print(json.dumps(dict(stage=str(output),manifestSha256=sha(output/'stage.json'),membership=membership,
        added=manifest['addedFamilyEdges'],unchangedFamilies=len(manifest['unchangedFamilyEdges']),compilerFiles=len(compiler_rows)),indent=2))
    return output


if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--version',default='v33-sewer-v1')
    p.add_argument('--room-declaration',type=Path);p.add_argument('--room-sha256');a=p.parse_args();stage(a.version,a.room_declaration,a.room_sha256)

"""Check a frozen sewer stage and optionally run its existing compiler."""
import argparse,json
from pathlib import Path
from run_frozen_v32_contact_stage import sha


def main(stage,bake=False):
    manifest=json.loads((stage/'stage.json').read_text())
    assert Path(__file__).resolve().parent==(stage/'compiler').resolve()
    for row in [manifest['baseBindings'],manifest['basePack'],*manifest['reviewedDeclarations'],*manifest['evidenceFiles'],*manifest['checkedInputs'],*manifest['compilerFiles']]:
        assert sha(row['path'])==row['sha256'],row['path']
    assert sha(manifest['declarationFile'])==manifest['declarationSha256']
    families=json.loads(Path(manifest['declarationFile']).read_text())
    prior=json.loads(Path(manifest['baseBindings']['path']).read_text())
    changes={r['edge']:r for r in manifest['changedFamilyMembership']}
    replacements={r['edge']:r for r in manifest.get('replacedFamilyDeclarations',[])}
    for old in prior['families']:
        current=next(f for f in families if f['edge']==old['edge'])
        if old['edge'] in replacements:
            row=replacements[old['edge']]['declaration']
            assert sha(row['path'])==row['sha256']
            assert current==json.loads(Path(row['path']).read_text())
        elif old['edge'] in changes:
            row=changes[old['edge']]
            assert current['objects']==row['retainedObjects']
            assert [o for o in old['objects'] if o not in row['removedObjects']]==current['objects']
            assert {**current,'objects':old['objects']}==old
        else:assert current==old
    print(json.dumps(dict(stage=str(stage),hashChecksPassed=True,bakeRequested=bake)),flush=True)
    if bake:
        from build_split_normalized_wall_families import main as build
        build(out=Path(manifest['candidateOutput']),frozen_families=families)


if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('stage',type=Path);p.add_argument('--bake',action='store_true');a=p.parse_args();main(a.stage,a.bake)

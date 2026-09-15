"""Verify a frozen V32 stage; bake only when explicitly invoked with --bake."""
import argparse,hashlib,json
from pathlib import Path

def sha(path):return hashlib.sha256(Path(path).read_bytes()).hexdigest()
def main(stage,bake=False):
    manifest=json.loads((stage/'stage.json').read_text());assert Path(__file__).resolve().parent==(stage/'compiler').resolve(),'Run the frozen compiler copy'
    for row in [manifest['baseBindings'],manifest['basePack'],*manifest['reviewedDeclarations'],*manifest['evidenceFiles'],*manifest.get('dependencyEvidence',[]),*manifest['checkedInputs'],*manifest['compilerFiles']]:
        assert sha(row['path'])==row['sha256'],row['path']
        if 'frozenCopy'in row:assert sha(row['frozenCopy'])==row['sha256']
    assert sha(manifest['declarationFile'])==manifest['declarationSha256']
    families=json.loads(Path(manifest['declarationFile']).read_text());prior=json.loads(Path(manifest['baseBindings']['path']).read_text())
    for old in prior['families']:
        if old['edge']in manifest['removedFamilyEdges']:continue
        assert old==next(f for f in families if f['edge']==old['edge'])
    print(json.dumps(dict(stage=str(stage),hashChecksPassed=True,literalUnchangedFamilies=len(manifest['unchangedFamilyEdges']),bakeRequested=bake)),flush=True)
    if bake:
        from build_split_normalized_wall_families import main as build
        build(out=Path(manifest['candidateOutput']),frozen_families=families)

if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('stage',type=Path);p.add_argument('--bake',action='store_true');a=p.parse_args();main(a.stage,a.bake)

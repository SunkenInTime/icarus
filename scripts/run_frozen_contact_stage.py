"""Run only a hash-bound, isolated connected-contact compiler snapshot."""
import argparse
import hashlib
import json
from pathlib import Path


def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def main(stage):
    manifest=json.loads((stage/'stage.json').read_text())
    assert Path(__file__).resolve().parent==(stage/'compiler').resolve(), 'Run the frozen compiler copy'
    for row in [manifest['baseBindings'],manifest['basePack'],*manifest['reviewedDeclarations'],*manifest['compilerFiles']]:
        assert digest(row['path'])==row['sha256'],row['path']
    assert digest(manifest['declarationFile'])==manifest['declarationSha256']
    from build_split_normalized_wall_families import main as bake
    bake(out=Path(manifest['candidateOutput']),frozen_families=json.loads(Path(manifest['declarationFile']).read_text()))


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('stage',type=Path)
    main(parser.parse_args().stage)

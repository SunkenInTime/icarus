"""Freeze reviewed connected wall declarations and an isolated offline compiler."""
import argparse
from copy import deepcopy
import json
from pathlib import Path
import shutil

from declare_split_legacy105_connected_region import REV, sha


def stage(version, additions):
    base_path=REV/'split-wall-family-normalized-candidate-v30-cached-v1/bindings.json'
    base=json.loads(base_path.read_text())
    main_path=REV/'split-legacy105-connected-region-proposal-v7/combined-declarations.json'
    main,bottom=json.loads(main_path.read_text())
    assert main['edge']==200105 and bottom['edge']==200140
    families=deepcopy(base['families'])
    # The connected105 source section owns its actual7898 corner before106.
    # The checked106 seam keeps the existing along map at their shared endpoint.
    assert sum(f['edge']==105 for f in families)==1
    families=[f for f in families if f['edge']!=105]
    families.insert(0,main)
    families.append(bottom)
    sources=[main_path]
    for path in additions:
        value=json.loads(path.read_text());extra=value if isinstance(value,list) else [value]
        for family in extra:
            assert family['edge'] not in {f['edge'] for f in families}, 'Use an explicit reviewed replacement for an existing family'
            families.append(family)
        sources.append(path)
    assert len({f['edge'] for f in families})==len(families)
    for family in base['families']:
        if family['edge']==105:continue
        assert family==next(f for f in families if f['edge']==family['edge'])
    # Bottom continuation is strictly outside previous7897 owner boxes.
    for family in base['families']:
        if 7897 in family['objects']:
            assert family['box'][3]<bottom['box'][1]
    output=REV/f'split-connected-contact-stage-{version}'
    output.mkdir(exist_ok=False)
    declarations=output/'family-declarations.json'
    declarations.write_text(json.dumps(families,indent=2)+'\n')
    compiler=output/'compiler';compiler.mkdir()
    files=[]
    # Freeze Python inputs before running, so concurrent diagnostic work cannot
    # change a half-finished bake. Only Python sources are needed by this builder.
    for source in sorted(Path('scripts').glob('*.py')):
        destination=compiler/source.name;shutil.copyfile(source,destination)
        files.append(dict(path=str(destination),sha256=sha(destination)))
    manifest=dict(version=version,baseBindings=dict(path=str(base_path),sha256=sha(base_path)),
        basePack=dict(path=str(base_path.parent/'split.height.bin.gz'),sha256=sha(base_path.parent/'split.height.bin.gz')),
        reviewedDeclarations=[dict(path=str(p),sha256=sha(p)) for p in sources],
        declarationFile=str(declarations),declarationSha256=sha(declarations),
        compilerFiles=files,candidateOutput=str(REV/f'split-wall-family-normalized-candidate-{version}'),
        changedOwnership='Replace legacy105 with the source-reviewed200105 assembly before106, plus separate lower200140 beyond prior7897 boxes. Keep all other V30 declarations literal.',
        floorPolicy='Existing provisional ground field. This bake does not claim to solve ramps.',productionMutation=False)
    (output/'stage.json').write_text(json.dumps(manifest,indent=2)+'\n')
    print(json.dumps(dict(stage=str(output),families=len(families),compilerFiles=len(files)),indent=2))
    return output


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--version',required=True)
    parser.add_argument('--add-declaration',type=Path,action='append',default=[])
    args=parser.parse_args();stage(args.version,args.add_declaration)

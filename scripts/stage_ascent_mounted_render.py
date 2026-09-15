"""Replay the frozen V5 Ascent poses against the complete mounted assemblies."""
import argparse
import copy
import json
from pathlib import Path

from native_compact_wall_profiles import sha
from prepare_ascent_connected_corners import REV


def main(folder,prior=None,scope=None):
    folder=Path(folder)
    prior=Path(prior) if prior else REV/'ascent-connected-component5-candidate-v5/render-fixtures'
    fixture=json.loads((prior/'ascent-fixtures.json').read_text())
    config=json.loads((prior/'candidate-config.json').read_text())
    summary=json.loads((folder/'summary.json').read_text())
    for row in fixture['cases']:
        if row['id'].startswith('preserved-opening-'):
            row['priorPrimaryOnlyProfileControl']={k:row.pop(k) for k in
                ['expectedAtAuthoredContact','sourceSectionClearanceSvg','sourceEvidence'] if k in row}
            row['category']='Frozen primary-only gap control; complete mounted source and alpha masks may block'
    cfg=config['maps']['ascent']
    cfg.update(folder=str(folder/'native'),candidatePackSha256=summary['packSha256'],
               scopeLabel=scope or 'Reviewed component5 with complete mounted paper, static door, open window-frame and conduit profiles')
    config['scope']=cfg['scopeLabel']+'; control-relative heights remain provisional; no production promotion'
    out=folder/'render-fixtures'
    out.mkdir(exist_ok=True)
    for filename, data in [('ascent-fixtures.json',fixture),('candidate-config.json',config)]:
        path=out/filename
        if path.exists():raise FileExistsError(path)
        path.write_text(json.dumps(data,indent=2)+'\n')
    proof=dict(priorFixturesSha256=sha(prior/'ascent-fixtures.json'),
               priorConfigSha256=sha(prior/'candidate-config.json'),bindingsSha256=sha(folder/'bindings.json'),
               candidatePackSha256=summary['packSha256'],scriptSha256=sha(Path(__file__)),
               identicalFrozenQueries=cfg['queriesById']==json.loads((prior/'candidate-config.json').read_text())['maps']['ascent']['queriesById'],
               sourceScope=f'Same{len(fixture["cases"])} original physical query poses. Source scope remains explicit per case; primary-only gap controls do not imply clear through later reviewed mounted geometry.')
    assert proof['identicalFrozenQueries']
    (out/'provenance.json').write_text(json.dumps(proof,indent=2)+'\n')
    print(out,len(fixture['cases']))


if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('candidate');p.add_argument('--prior');p.add_argument('--scope');args=p.parse_args();main(args.candidate,args.prior,args.scope)

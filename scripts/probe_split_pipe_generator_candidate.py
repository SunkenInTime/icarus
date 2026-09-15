"""Bounded exact-query source attribution for frozen pipe/generator renders."""
import json
from pathlib import Path

import numpy as np
from native_compact_wall_profiles import sha
from native_reference_cast import NativeReferenceModel

ROOT=Path('E:/IcarusWorldAudit/2026-09-06')
REV=ROOT/'tactical-visibility-revision'


def main():
    folder=REV/'split-pipe-generator-render-candidate-v30'
    output=folder/'native-first-hit-review.json'
    assert not output.exists()
    fixtures=json.loads((folder/'split-fixtures.json').read_text())['cases']
    configs={label:json.loads((folder/f'{label}-config.json').read_text())['maps']['split']
        for label in ['control','candidate']}
    full=np.load(REV/'full-height-input-v1/split/source-correspondence.npz')['sourceFaces']
    control=np.load(REV/'global-ground-complete-v2/split/correspondence.npz')['sourceFaces']
    raw_source=full[control]
    meta=json.loads((ROOT/'supplemented-v2/world/split/geometry.json').read_text())
    starts=np.array([o['firstFace'] for o in meta['objects']])
    models={};parents={};hashes={}
    for label,cfg in configs.items():
        pack=Path(cfg['folder']).parent/'split.height.bin.gz'
        assert sha(pack)==cfg['candidatePackSha256']
        models[label]=NativeReferenceModel(pack,REV/'native-tactical-rays-build/Release/tactical_reference_cast.dll')
        parents[label]=np.load(pack.parent/'correspondence.npz')['sourceFaces']
        hashes[label]=sha(pack)
    rows=[]
    for fixture in fixtures:
        identifier=fixture['id'];query=np.array(configs['candidate']['queriesById'][identifier])
        assert query.tolist()==configs['control']['queriesById'][identifier]
        target=query[:3].copy();target[:2]+=query[3:5]*query[5]
        hits={}
        for label,model in models.items():
            hit=model.cast(query[:3],target)
            if hit:
                control_parent=int(parents[label][hit['face']]);raw=int(raw_source[control_parent])
                owner=int(np.searchsorted(starts,raw,side='right')-1)
                hit.update(controlParent=control_parent,originalSourceFace=raw,sourceObject=owner,
                    sourceObjectPath=meta['objects'][owner]['path'])
            hits[label]=hit
        distances={k:h['distanceMeters'] if h else float(query[5]) for k,h in hits.items()}
        difference=distances['candidate']-distances['control']
        invariant=identifier.startswith('clove-left-opening-invariant')
        if invariant:
            assert abs(difference)<1e-8,(identifier,distances)
            assert (hits['control'] is None)==(hits['candidate'] is None)
            if hits['control']:
                assert hits['control']['originalSourceFace']==hits['candidate']['originalSourceFace']
        rows.append(dict(id=identifier,query=query.tolist(),firstHits=hits,
            distanceChangeMeters=difference,leftOpeningInvariantChecked=invariant))
    report=dict(packSha256=hashes,fixtureSha256=sha(folder/'split-fixtures.json'),rows=rows,
        scope='Exact center rays under the same provisional control floor policy. Does not replace original-world-height or full-cone/render review.',
        productionMutation=False)
    output.write_text(json.dumps(report,indent=2)+'\n')
    print(json.dumps([dict(id=r['id'],distanceChangeMeters=r['distanceChangeMeters'],
        controlObject=r['firstHits']['control']['sourceObject'] if r['firstHits']['control'] else None,
        candidateObject=r['firstHits']['candidate']['sourceObject'] if r['firstHits']['candidate'] else None)
        for r in rows],indent=2))


if __name__=='__main__':main()

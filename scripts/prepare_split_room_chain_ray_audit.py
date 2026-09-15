"""Combine held raw partitions and freeze the shared original-standing ray harness."""
import json
from pathlib import Path
import numpy as np
from lift_reviewed_wall_source_heights import sha

REV=Path('E:/IcarusWorldAudit/2026-09-06/tactical-visibility-revision')
out=REV/'split-room-upper-chain-combined-raw-v2';out.mkdir(exist_ok=False)
paths=[REV/'split-vent-room-raw-partition-v3/raw-source-fragments.npz',REV/'split-upper-vent-chain-raw-partition-v2/raw-source-fragments.npz']
data=[np.load(p)for p in paths];assert not(set(data[0]['originalSourceFaces'])&set(data[1]['originalSourceFaces']))
arrays={k:np.concatenate([d[k]for d in data])for k in data[0].files}
np.savez_compressed(out/'raw-source-fragments.npz',**arrays)
(out/'partition-review.json').write_text(json.dumps(dict(inputs=[dict(path=str(p),sha256=sha(p),partitionReportSha256=sha(p.parent/'partition-review.json'))for p in paths],
    sourceParents=len(arrays['originalSourceFaces']),fragmentCount=len(arrays['sourceFaces']),sourceParentsDisjoint=True,status='Concatenated held raw source partitions; no production pack.'),indent=2)+'\n')
template=Path('scripts/audit_split_vent_room_composed_rays.py');code=template.read_text()
code=code.replace('split-vent-room-composed-standing-rays-v5','split-room-upper-chain-standing-rays-v2').replace('split-vent-room-raw-partition-v3','split-room-upper-chain-combined-raw-v2')
code=code.replace("(172,1,168.451,263.9,298.5,1)","(172,1,168.451,263.9,298.5,1),(169,0,281.201,101.1,141.7,1),(170,1,141.87,281.4,298.5,-1),(171,0,298.744,142.1,168.3,1)")
code=code.replace("declarationSha256=sha(REV/'split-vent-room-finite-field-experiment-v6/sealed-held-region-declaration.json'),", "declarationSha256=sha(REV/'split-vent-room-finite-field-experiment-v6/sealed-held-region-declaration.json'),upperChainDeclarationSha256=sha(REV/'split-upper-vent-chain-field-proposal-v2/held-region-declaration.json'),")
target=Path('scripts/audit_split_room_upper_chain_composed_rays_v2.py');assert not target.exists();target.write_text(code)
(out/'harness-provenance.json').write_text(json.dumps(dict(templateSha256=sha(template),harnessSha256=sha(target),generatorSha256=sha(Path(__file__)),changes='Only fragment input/output, additional169–171 source-floor probes, and second declaration provenance. Original416 queries retained.'),indent=2)+'\n')
print(str(target))

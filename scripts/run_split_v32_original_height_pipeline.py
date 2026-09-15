"""Run the independent V32 source gates and original-height composition offline."""
import json,subprocess,sys
from pathlib import Path
from datetime import datetime,timezone

REV=Path('E:/IcarusWorldAudit/2026-09-06/tactical-visibility-revision');stage=REV/'split-connected-contact-stage-v32-precise-v1';compiler=stage/'compiler'
candidate=REV/'split-wall-family-normalized-candidate-v32-precise-v1';lifted=REV/'split-source-world-fragments-v32-v1';oracle=REV/'split-source-height-region-oracle-v32-v1';complete=REV/'split-complete-control-original-height-v32-v1'
warp=REV/'display-warps-v1/split.display-warp.json.gz';full=REV/'full-height-input-v1/split/split.height.bin.gz'
steps=[('candidate-source-gate',[compiler/'verify_normalized_wall_profiles.py',candidate,'--warp',warp,'--report',candidate/'root-independent-profile-review.json']),
    ('literal-unaffected-families',[Path(__file__).with_name('verify_split_v32_unchanged_families.py')]),
    ('restore-source-z',[compiler/'lift_reviewed_wall_source_heights.py',candidate,warp,full,lifted,'--proof',candidate/'root-independent-profile-review.json']),
    ('compile-source-subset',[compiler/'compile_reviewed_source_world_oracle.py',lifted,candidate,warp,oracle]),
    ('verify-source-z-material',[compiler/'verify_source_height_region_oracle.py',oracle,candidate,full,oracle/'root-height-material-review.json']),
    ('verify-restored-source-xy',[compiler/'verify_restored_source_xy.py',oracle,candidate,warp,oracle/'root-restored-xy-review.json']),
    ('compose-original-height-control-domain',[compiler/'compile_complete_source_height_oracle.py',candidate,lifted,oracle,full,complete]),
    ('verify-complete-composition',[compiler/'verify_complete_source_height_oracle.py',complete,candidate,oracle,complete/'root-independent-composition-review.json'])]
records=[];status=stage/'original-height-pipeline-status.json'
def save():status.write_text(json.dumps(dict(steps=records,updatedUtc=datetime.now(timezone.utc).isoformat(),productionMutation=False),indent=2)+'\n')
for name,args in steps:
    log=stage/f'{name}.log';row=dict(step=name,command=[sys.executable,*map(str,args)],startedUtc=datetime.now(timezone.utc).isoformat(),log=str(log),state='running');records.append(row);save();print(json.dumps(dict(step=name,state='running')),flush=True)
    with log.open('w')as output:result=subprocess.run(row['command'],stdout=output,stderr=subprocess.STDOUT)
    row.update(finishedUtc=datetime.now(timezone.utc).isoformat(),exitCode=result.returncode,state='passed'if result.returncode==0 else'failed');save();print(json.dumps(dict(step=name,state=row['state'])),flush=True)
    if result.returncode:raise SystemExit(result.returncode)
    if name=='candidate-source-gate':(candidate/'independent-profile-review.json').write_bytes((candidate/'root-independent-profile-review.json').read_bytes())

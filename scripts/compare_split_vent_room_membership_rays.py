"""Compare frozen physical rays before and after the three wall member additions."""
import json
from pathlib import Path
import numpy as np
from lift_reviewed_wall_source_heights import sha

REV=Path('E:/IcarusWorldAudit/2026-09-06/tactical-visibility-revision')
before=REV/'split-vent-room-composed-standing-rays-v4/composed-rays.json'
after=REV/'split-vent-room-composed-standing-rays-v5/composed-rays.json'
a=json.loads(before.read_text());b=json.loads(after.read_text())
assert len(a['records'])==len(b['records'])==416
summary={};changed=[];unaffected=[]
for index,(old,new) in enumerate(zip(a['records'],b['records'])):
    for key in ['originalEye','originalTarget','navTriangle','navParent','targetRole','gridProbe']:
        assert old[key]==new[key],(index,key)
    old_hit,new_hit=old['after'],new['after']
    delta=None if old_hit is None or new_hit is None else float(np.linalg.norm(np.array(old_hit['point'])-new_hit['point']))
    same=(old_hit is None and new_hit is None) or (delta is not None and delta<1e-12)
    (unaffected if same else changed).append(index)
    if new['gridProbe']:
        edge=new['gridProbe']['edge'];axis=new['gridProbe']['wallAxis'];fixed=new['gridProbe']['authoredFixed']
        item=summary.setdefault(str(edge),dict(count=0,objects={},clear=[]))
        item['count']+=1
        if new_hit:
            bucket=item['objects'].setdefault(str(new_hit['sourceObject']),dict(rows=[],errors=[]))
            bucket['rows'].append(index);bucket['errors'].append(new_hit['displaySvg'][axis]-fixed)
        else:item['clear'].append(index)
for group in summary.values():
    for item in group['objects'].values():
        item['normalErrorRangeSvg']=[min(item['errors']),max(item['errors'])]
        del item['errors']
report=dict(beforeSha256=sha(before),afterSha256=sha(after),scriptSha256=sha(Path(__file__)),
    frozenQueriesIdentical=416,changedHitIndices=changed,unchangedHitIndices=unaffected,grid=summary,
    scope='Original source floor standing sections only. Unchanged queries; no final tactical receiver policy or production bake.')
(after.parent/'membership-comparison.json').write_text(json.dumps(report,indent=2)+'\n')
print(json.dumps(dict(changed=len(changed),unchanged=len(unaffected),grid=summary)))

"""Frozen room preservation and new chain first-hit coordinate checks."""
import json
from pathlib import Path
import numpy as np
from lift_reviewed_wall_source_heights import sha
from verify_region_contact import segment_cells,interval_values

REV=Path('E:/IcarusWorldAudit/2026-09-06/tactical-visibility-revision')
oldp=REV/'split-vent-room-composed-standing-rays-v5/composed-rays.json';newp=REV/'split-room-upper-chain-standing-rays-v2/composed-rays.json'
a=json.loads(oldp.read_text());b=json.loads(newp.read_text());changed=[]
for i,(old,new)in enumerate(zip(a['records'],b['records'])):
    for key in ['originalEye','originalTarget','navTriangle','navParent','targetRole','gridProbe']:assert old[key]==new[key],(i,key)
    ah,bh=old['after'],new['after']
    if ah is None or bh is None:
        if ah!=bh:changed.append(i)
    elif np.linalg.norm(np.array(ah['point'])-bh['point'])>1e-12:changed.append(i)
summary={}
for i,r in enumerate(b['records']):
    if not r['gridProbe']:continue
    edge=r['gridProbe']['edge'];key=str(edge);group=summary.setdefault(key,dict(rows=[],hits={},clear=[]));group['rows'].append(i)
    h=r['after']
    if not h:group['clear'].append(i);continue
    key=str(h['sourceObject']);item=group['hits'].setdefault(key,dict(rows=[],normalErrorSvg=[]));item['rows'].append(i)
    item['normalErrorSvg'].append(h['displaySvg'][r['gridProbe']['wallAxis']]-r['gridProbe']['authoredFixed'])
for g in summary.values():
    for h in g['hits'].values():h['normalErrorRangeSvg']=[min(h['normalErrorSvg']),max(h['normalErrorSvg'])];del h['normalErrorSvg']
roomp=REV/'split-vent-room-finite-field-experiment-v6/sealed-held-region-declaration.json';chainp=REV/'split-upper-vent-chain-field-proposal-v2/held-region-declaration.json'
room=json.loads(roomp.read_text());chain=json.loads(chainp.read_text());checks=[]
for end in [281.02095268433897,281.2456484422984,283.6277601036635]:
    lo=275.38123294219076;sa=segment_cells(room,np.array([[lo,169.45555596144112],[end,169.45555596144112]]));sb=segment_cells(chain,np.array([[lo,169.4555708754589],[end,169.4555708754589]]))
    breaks=np.unique(np.r_[sa[-1],sb[-1]]);maximum=0
    for start,stop in zip(breaks[:-1],breaks[1:]):
        aa=interval_values(sa,start,stop);bb=interval_values(sb,start,stop);maximum=max(maximum,float(abs(aa[:,None]-bb[None]).max()))
    checks.append(dict(sourceX=[lo,end],roomSourceY=169.45555596144112,chainSourceY=169.4555708754589,maximumContinuousCoordinateDisagreementSvg=maximum,affineIntervals=len(breaks)-1))
report=dict(beforeSha256=sha(oldp),afterSha256=sha(newp),scriptSha256=sha(Path(__file__)),identicalFrozenQueries=len(a['records']),changedFrozenHitIndices=changed,
    grid=summary,continuousRoom172Correspondence=checks,status='Original source standing section checks only. No application cone or tactical layer-policy acceptance.')
(newp.parent/'contact-and-preservation-review.json').write_text(json.dumps(report,indent=2)+'\n')
print(json.dumps(dict(changedFrozen=changed,grid=summary,room172=checks)))

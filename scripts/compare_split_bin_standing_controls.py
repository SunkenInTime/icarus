"""Bind the unchanged standing queries to the attached-bin membership result."""
import json
from pathlib import Path
import numpy as np
from declare_split_legacy105_connected_region import REV, sha


def main():
    groups=[]
    for group,stem in [('top','split-legacy105-top-controls-sealed'),('lower','split-legacy105-lower-receiver-review')]:
        paths=[REV/f'{stem}-v{v}/first-hit-controls.json' for v in [6,7]]
        old,new=[json.loads(p.read_text()) for p in paths]
        assert old['fixtures']==new['fixtures']
        assert len(old['records'])==len(new['records'])
        changed=[];unchanged=0
        for index,(a,b) in enumerate(zip(old['records'],new['records'])):
            for key in ['originId','queryStart','queryEnd','targetSvg','sideReceiver','displayPath']:
                assert a[key]==b[key],(group,index,key)
            before,after=a['proposedHybridHit'],b['proposedHybridHit']
            if before==after:unchanged+=1;continue
            assert group=='top' and before['sourceObject']==7852 and after['sourceObject']==7899
            assert abs(after['displayedHitSvg'][0]-279.074)<1e-10
            assert after['distanceMeters']>before['distanceMeters']
            changed.append(dict(queryIndex=index,originId=a['originId'],before=before,after=after))
        groups.append(dict(group=group,sourceReports=[dict(path=str(p),sha256=sha(p)) for p in paths],
            identicalQueries=len(old['records']),unchangedHits=unchanged,changedHits=changed))
    assert len(groups[0]['changedHits'])==3 and not groups[1]['changedHits']
    report=dict(scriptSha256=sha(Path(__file__)),groups=groups,productionMutation=False,
        scope='Frozen original-height source-section controls. All three premature bin contacts now reach the existing SVG-aligned wall. Every other top or lower hit is literally unchanged. This does not replace candidate or product render validation.')
    out=REV/'split-wall-bin7852-finite-review-v1/frozen-standing-controls.json'
    assert not out.exists();out.write_text(json.dumps(report,indent=2)+'\n')
    print(json.dumps([{k:v if k!='changedHits' else len(v) for k,v in r.items() if k!='sourceReports'} for r in groups],indent=2))


if __name__=='__main__':main()

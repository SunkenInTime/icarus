"""Classify frozen unresolved projection faces using rational geometry."""
import argparse
from collections import Counter
import json
from pathlib import Path
import numpy as np
from exact_receiver_contact import classify
from finite_receiver_shadows import Receiver
from lift_reviewed_wall_source_heights import sha


def audit(fixtures, output):
    if output.exists():raise FileExistsError(output)
    frozen=json.loads((fixtures/'report.json').read_text())
    results=[]
    for row in frozen['records']:
        path=fixtures/(row['id']+'.npz')
        with np.load(path) as archive:data={k:archive[k] for k in archive.files}
        ids={int(face):i for i,face in enumerate(data['sourceFaceIds'])}
        receiver=Receiver(data['receiverFootprint'],data['receiverPlane'])
        for contact in row['contactFallback']:
            face=contact['sourceFace'];i=ids[face]
            assert data['faceMasks'][i]<0
            exact=classify(data['observer'],data['sourceTriangles'][i],receiver)
            results.append(dict(id=row['id'],sourceFace=face,originalReason=contact['reason'],
                fixtureSha256=sha(path),exact=exact))
    counts=Counter(x['exact']['kind'] for x in results)
    positive=[x['exact']['areaSquareMeters'] for x in results if x['exact']['kind']=='exact-positive-area-shadow']
    report=dict(scope=__doc__,fixtureReportSha256=sha(fixtures/'report.json'),occurrences=len(results),
        classificationCounts=dict(counts),maximumPositiveShadowAreaSquareMeters=max(positive,default=0),records=results,
        classifierSha256=sha(Path(__file__).with_name('exact_receiver_contact.py')),auditorSha256=sha(Path(__file__)),
        limitations=['Exact refers to stored source vertices, eye and affine receiver coefficients.',
            'No fallback identities removed or runtime behavior changed.',
            'Zero-area bounds describe filled shadows, not line/point contact policy.',
            'Coplanar source/eye/receiver cases still need a 2D contact decision.'])
    output.mkdir(parents=True);(output/'report.json').write_text(json.dumps(report,indent=2)+'\n')
    print(json.dumps({k:v for k,v in report.items() if k!='records'},indent=2))


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    for key in ['fixtures','output']:parser.add_argument(key,type=Path)
    audit(**vars(parser.parse_args()))

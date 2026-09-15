"""Add a source-reviewed attached bin to an otherwise unchanged wall field."""
from copy import deepcopy
import json
from pathlib import Path

from declare_split_legacy105_connected_region import ROOT, REV, sha


def main():
    source=REV/'split-legacy105-connected-region-proposal-v6/combined-declarations.json'
    evidence=REV/'split-wall-bin7852-attachment-proposal-v1/report.json'
    review=json.loads(evidence.read_text())
    metadata=ROOT/'supplemented-v2/world/split/geometry.json'
    assert sha(metadata)==review['sourceMetadataSha256']
    assert review['binProjectionEntirelyWithinOriginalWall']
    assert review['intersectingBinFaces']==188
    assert sha(source.parent/'region-declaration.json')==review['existingFieldSha256']
    assert sha(evidence.parent/'source-attachment.npz')==review['sourcePacketSha256']
    obj=json.loads(metadata.read_text())['objects'][7852]
    ids=list(range(obj['firstFace'],obj['firstFace']+obj['faceCount']))
    assert len(ids)==904
    before=json.loads(source.read_text());after=deepcopy(before)
    wall=after[0];assert wall['edge']==200105
    assert not set(ids).intersection(wall['reviewedSourceFaces'])
    wall['objects'].append(7852)
    wall['reviewedSourceFaces']=sorted(wall['reviewedSourceFaces']+ids)
    wall['attachedDetailPolicy']={
        'object':7852,'rawSourceFaces':ids,
        'role':'Wall detail absent from the SVG, intersecting the literal existing wall. Apply the same wall field to the complete object.',
        'sourceAttachmentEvidence':{'path':str(evidence),'sha256':sha(evidence)},
        'sourceHeightUvMaterials':'Unchanged. This membership edit does not discard source faces or extrude a wall.'}
    wall['reviewStatus']='Source attachment personally reviewed. Proposal awaits full source partition and candidate render gates.'
    # All geometry and mapping semantics remain literally identical.
    mutable={'objects','reviewedSourceFaces','attachedDetailPolicy','reviewStatus'}
    assert {k:v for k,v in wall.items() if k not in mutable}=={k:v for k,v in before[0].items() if k not in mutable}
    assert after[1]==before[1]
    out=REV/'split-legacy105-connected-region-proposal-v7';out.mkdir(exist_ok=False)
    for filename,value in [('region-declaration.json',wall),('bottom-continuation-declaration.json',after[1]),('combined-declarations.json',after)]:
        (out/filename).write_text(json.dumps(value,indent=2)+'\n')
    report={'sourceDeclarationSha256':sha(source),'attachmentEvidenceSha256':sha(evidence),
        'declarationSha256':sha(out/'combined-declarations.json'),'scriptSha256':sha(Path(__file__)),
        'addedSourceObject':7852,'addedRawFaces':len(ids),'finiteFieldAndMappingSemanticsUnchanged':True,
        'bottomContinuationUnchanged':True,'productionMutation':False,
        'remainingChecks':['Frozen first-hit queries','Full candidate source partition and unchanged Z/UV','Both-side actual rendered wall contacts']}
    (out/'membership-review.json').write_text(json.dumps(report,indent=2)+'\n')
    print(json.dumps(report,indent=2))


if __name__=='__main__':main()

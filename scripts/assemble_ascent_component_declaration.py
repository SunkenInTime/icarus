"""Assemble reviewable finite Ascent component declarations, refusing incomplete bakes."""
import gzip
import json
from collections import defaultdict
from pathlib import Path
import numpy as np
from native_compact_wall_profiles import sha
from prepare_ascent_connected_corners import ROOT, REV, OUT


def main():
    primary_path=OUT/'connected-proposals.json'
    returns_path=OUT/'structural-return-declarations.json'
    inserts_path=OUT/'insert-proposals.json'
    primary=json.loads(primary_path.read_text())
    returns=json.loads(returns_path.read_text())
    inserts=json.loads(inserts_path.read_text())
    folder=REV/'ascent-connected-contour-proposals-v1'
    hosts={f['edge']:f for c in primary['chains'] for f in c['families']}
    caps={f['completeSpan']:f for f in returns['declarations']}
    raw_path=ROOT/'supplemented-v2/world/ascent/geometry.npz'
    raw=np.load(raw_path)
    points,faces=raw['points'],raw['faces']
    affine=np.array(json.loads((ROOT/'tactical-alignment-sides-v1/ascent.json').read_text())['nativeToAttackSvg'])
    components=[]
    owner_by_face=defaultdict(list)
    max_bary_height_error=0.
    checked_fragments=0
    for component in [5,7]:
        component_path=folder/f'component-{component}.json.gz'
        source=json.loads(gzip.decompress(component_path.read_bytes()))
        entries=[]
        for span in source['spans']:
            number=span['completeSpan']
            entry=dict(completeSpan=number,authoredEndpoints=span['authoredEndpoints'],sourceProposalRef=dict(file=str(component_path),sha256=sha(component_path),completeSpan=number),families=[],unresolvedReasons=[])
            if number in hosts:
                host=hosts[number]
                entry['families'].append(dict(role='reviewed-primary',sourceObject=host['objects'][0],sourceFrame=host['sourceFrame'],targetFrame=host['targetFrame'],sourceAlong=host['sourceAlong'],targetAlong=host['targetAlong'],reviewedSourceFaces=host['reviewedSourceFaces'],originalHeightFragments=host['originalHeightFragments'],joinPolicy='Reuse the approved primary shared source joins. Incident supplementary source assemblies retain their separately verified profiles.',approval='Root personally reviewed source geometry; finite complete-component ownership and closure remain pending.'))
                entry['unresolvedReasons'].append('attached-relief-and-incident-family-closure-pending')
            elif number in caps:
                cap=caps[number]
                entry['families'].append(dict(role='source-reviewed-structural-return',sourceObject=cap['sourceObject'],sourceFrame=cap['sourceFrame'],targetFrame=cap['targetFrame'],sourceAlong=cap['sourceAlong'],targetAlong=cap['targetAlong'],reviewedSourceFaces=cap['reviewedSourceFaces'],originalHeightFragments=cap['originalHeightFragments'],joins=cap['joins'],outsideSourceFragments=cap['outsideSourceFragments'],attachedFacetCandidates=cap['unassignedAttachedFacets'],approval='Source geometry personally reviewed by native agent. Explicit finite declarations await root review.'))
                entry['unresolvedReasons'].append('attached-cap-face-ownership-and-height-closure-pending')
            else:
                entry['unresolvedReasons'].append('source-plane-family-selection-and-finite-ownership-pending')
            if number==208:
                entry['unresolvedReasons']=['nonplanar-boat-source-profile-has-no-confirmed-diagonal-wall-correspondence']
                entry['specialSourceObjects']=[7206,7225,6959,7556]
                entry['prohibitedFallback']='Do not replace this receiver edge with a full-height opaque wall.'
            for insert in inserts['inserts']:
                if insert['span']!=number:
                    continue
                host=hosts[number]
                entry['families'].append(dict(role='reviewed-static-insert',sourceObject=insert['sourceObjectIndex'],sourceFrame=host['sourceFrame'],targetFrame=host['targetFrame'],sourceAlong=host['sourceAlong'],targetAlong=host['targetAlong'],reviewedSourceFaces=insert['sourceFaceIds'],originalTrianglesNative=insert['sourceTrianglesNative'],depthBoundsSvg=insert['sourceDepthBoundsSvg'],hostSpan=number,approval='Root personally reviewed and approved exact insert source profiles; preserve remaining opening space.',heightPolicy='Map only exact source triangles to the host wall frame. Preserve all original Z/UV/material and frozen source state; never fill the surrounding opening.'))
            for family in entry['families']:
                for face in family['reviewedSourceFaces']:
                    owner_by_face[face].append([number,family['role']])
                for fragment in family.get('originalHeightFragments',[]):
                    xyz=points[faces[fragment['sourceFace']]]
                    weights=np.array(fragment['sourceBarycentrics'])
                    assert weights.min()>=-1e-10 and abs(weights.sum(1)-1).max()<1e-10
                    expected_z=xyz[0,2]+weights[:,1]*(xyz[1,2]-xyz[0,2])+weights[:,2]*(xyz[2,2]-xyz[0,2])
                    error=float(abs(expected_z-np.array(fragment['targetAlongZ'])[:,1]).max())
                    max_bary_height_error=max(max_bary_height_error,error)
                    checked_fragments+=1
            entry['bakeAllowed']=False
            entries.append(entry)
        joins=[]
        for left,right in zip(entries,entries[1:]+entries[:1]):
            assert left['authoredEndpoints'][1]==right['authoredEndpoints'][0]
            joins.append(dict(leftSpan=left['completeSpan'],rightSpan=right['completeSpan'],targetSvg=left['authoredEndpoints'][1],requiredProofs=['Shared source vertices assigned to incident families must map to one authored join at each preserved height.','Original source fragments must form a complete nonoverlapping ownership partition, including relief and caps.','Original gaps in the combined incident source profiles must stay open.','Any moved source boundary incident to retained source must have a reviewed exact transition; no unverified connector or endpoint collapse.'],status='closure-not-yet-certified'))
        components.append(dict(component=component,closed=True,spanCount=len(entries),spans=entries,joins=joins,bakeAllowed=False))
    duplicates={str(face):owners for face,owners in owner_by_face.items() if len(owners)>1}
    assert max_bary_height_error<1e-10
    report=dict(format='icarus-finite-component-declaration-review-v1',map='ascent',components=components,sourceFileSha256=sha(raw_path),primaryProposalSha256=sha(primary_path),returnProposalSha256=sha(returns_path),insertProposalSha256=sha(inserts_path),scriptSha256=sha(Path(__file__)),verification=dict(closedAuthoredSpans=51,sourceHeightFragmentsChecked=checked_fragments,maximumOriginalBarycentricHeightErrorMeters=max_bary_height_error,duplicateSourceFaceOwnership=duplicates),sharedCapPolicy='Assign every exact source fragment once after subdivision at the relevant finite source joins. Never assign the same entire cap to both incident families. Keep source face, barycentric fragment, source assembly and authored join provenance.',productionMutation=False,bakeAllowed=False,blockingConditions=['Source family selection remains unresolved on 39 spans.','Attached relief/cap ownership and height closure remain unresolved for reviewed families.','Span208 has nonplanar boat geometry without an accepted wall-frame correspondence.'])
    (OUT/'finite-component-declaration-review.json').write_text(json.dumps(report,indent=2)+'\n')
    print(json.dumps(report['verification'],indent=2))


if __name__=='__main__':main()

"""Compile the reviewed closed component into finite shared-join family frames."""
import json
from pathlib import Path
import numpy as np
from native_compact_wall_profiles import sha
from prepare_ascent_connected_corners import ROOT,OUT,frame


def main():
    path=OUT/'finite-component-declaration-review-v2.json';review=json.loads(path.read_text());component=review['components'][0];spans={r['completeSpan']:r for r in component['spans']}
    def plane(span,obj,index):
        return next(p['sourcePlane'] for f in spans[span]['families'] if f['sourceObject']==obj for p in f['planeProposals'] if p['index']==index)
    # Source identities selected from the complete assembly packets. These are
    # incident structural sheets, rather than strongest/nearest first-hit rank.
    anchor_pairs={
        136:((136,670,5),(137,670,0)),137:None,138:None,
        139:((139,6497,0),(140,6499,1)),140:((140,6499,1),(141,6499,0)),
        141:((141,6499,0),(142,6499,0)),142:((142,6499,0),(143,6499,0)),
        143:((143,6499,0),(144,6506,0)),144:((144,6506,0),(145,6506,0)),
        145:((145,6506,0),(146,6506,0)),146:((146,6506,0),(147,8034,4)),
        147:((147,8034,4),(148,8034,0)),148:((148,8034,0),(149,8034,0)),
        149:((149,8034,0),(150,6502,0)),150:((150,6502,0),(151,6328,1)),
        151:((151,6328,1),(152,6328,0)),152:((152,6328,0),(136,6502,0))}
    joins={};affine=np.array(json.loads((ROOT/'tactical-alignment-sides-v1/ascent.json').read_text())['nativeToAttackSvg'])
    for left,pair in anchor_pairs.items():
        if pair is None:continue
        p,q=[plane(*x) for x in pair];xy=np.linalg.solve(np.array([p['normal'],q['normal']]),np.array([p['offset'],q['offset']]))
        joins[left]=dict(leftSpan=left,rightSpan=136 if left==152 else left+1,sourceSvg=xy.tolist(),targetSvg=spans[left]['authoredEndpoints'][1],sourcePlaneRefs=pair,derivation='Intersection of the explicitly reviewed incident structural source planes.')
    cp=OUT/'column-corner-collapse-declarations.json';corner=next(x for x in json.loads(cp.read_text())['declarations'] if x['span']==138)
    for contract in corner['cornerContracts']:
        left=137+contract['endpoint'];right=left+1
        edges=contract['bodySharedSourceEdges']+contract['neighborSharedSourceEdges'];xy=np.array([p for e in edges for p in e['sourceEdgeNative']])[:,:2]@affine[:,:2].T+affine[:,2]
        lt=np.diff(spans[left]['authoredEndpoints'],axis=0)[0];lt/=np.linalg.norm(lt);rt=np.diff(spans[right]['authoredEndpoints'],axis=0)[0];rt/=np.linalg.norm(rt)
        # Ending sheet uses the innermost end; starting sheet its innermost start.
        # Thus every verified seam vertex clamps to the same square SVG corner.
        anchor=np.linalg.solve(np.array([lt,rt]),np.array([(xy@lt).min(),(xy@rt).max()]))
        joins[left]=dict(leftSpan=left,rightSpan=right,sourceSvg=anchor.tolist(),targetSvg=contract['targetSvg'],derivation='Approved inner square-corner envelope of exact incident shared source edges; original height intervals remain unchanged.',contract=contract)
    families=[];extra=[]
    for number,row in spans.items():
        start=np.array(joins[152 if number==136 else number-1]['sourceSvg']);end=np.array(joins[number]['sourceSvg']);tf,tl=frame(*row['authoredEndpoints']);t=np.array(tf['tangent']);sl=float((end-start)@t)
        assert sl>0
        sf=dict(origin=start.tolist(),tangent=t.tolist(),normal=[-float(t[1]),float(t[0])])
        for index,selected in enumerate(row['families']):
            original=selected.get('reviewedWholeInsertFaces',selected['sourceFaces']);whole=False;corner_faces=[]
            if number==138 and selected['sourceObject']==667:
                original=sorted(set(corner['bodyFaces'])|{x['sourceFace'] for x in corner['collapsedVerticalBevels']}|{x['sourceFace'] for x in corner['preservedTopBottomBevels']});whole=True;corner_faces=corner['collapsedVerticalBevels']
            families.append(dict(edge=number+index*1000,completeSpan=number,sourceFrame=sf,targetFrame=tf,sourceAlong=[0.,sl],targetAlong=[0.,tl],sharedSourceJoins=[start.tolist(),end.tolist()],sharedAuthoredJoins=row['authoredEndpoints'],objects=[selected['sourceObject']],sourceObjects=[dict(sourceObjectIndex=selected['sourceObject'],path=selected['sourceObjectPath'])],reviewedSourceFaceIds=original,sourceRole=selected['role'],clipPolicy='whole-reviewed-square-column' if whole else 'finite-source-along-strip',reviewedCornerFaces=corner_faces,sourceSelectionId=selected['id'],cornerOwnership='Exact source nominations only; ordinary out-of-strip geometry retained. Approved column bevels clamp to their proved common corners.',heightPolicy='Original source profiles and alpha are retained; no height envelope.'))
    # The original rear plane belongs behind the start of span139; its two
    # immediate incident bevel faces were approved in the square-corner packet.
    # Record them explicitly for the attachment gate, never silently absorb an
    # entire column or neighbouring frontage through an expanded clipping box.
    for contract in corner['cornerContracts']:
        number=137 if contract['endpoint']==0 else 139
        assigned=set(fid for f in families if f['completeSpan']==number for fid in f['reviewedSourceFaceIds'])
        for e in contract['neighborSharedSourceEdges']:
            if e['sourceFace'] not in assigned:extra.append(dict(completeSpan=number,sourceFace=e['sourceFace'],requiredCorner=contract['targetSvg'],sharedSourceEdge=e['sourceEdgeNative'],status='Exact incident corner attachment; separate bounded assignment required before acceptance.'))
    report=dict(format='icarus-connected-component-frame-declarations-v1',map='ascent',component=5,closed=True,joins=[joins[n] for n in sorted(joins)],families=families,sourceReviewSha256=sha(path),columnCornerContractSha256=sha(cp),scriptSha256=sha(Path(__file__)),sourceFileSha256=review['sourceFileSha256'],pendingExactAttachments=extra,summary=dict(authoredSpans=17,sourceFamilies=len(families),sharedJoins=len(joins),pendingExactCornerAttachments=len(extra)),productionMutation=False,acceptance=False,scope='Executable finite source frame declarations. A diagnostic bake is allowed; attachment, profile-partition, native ray and rendered contact checks still gate acceptance.')
    out=OUT/'component5-compiled-frames-v1.json';out.write_text(json.dumps(report,indent=2)+'\n');print(json.dumps(report['summary'],indent=2))


if __name__=='__main__':main()

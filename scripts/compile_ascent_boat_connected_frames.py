"""Finite boat-silhouette registration with shared incident wall end planes."""
import json
from pathlib import Path
import numpy as np
from prepare_ascent_connected_corners import ROOT,OUT,frame
from native_compact_wall_profiles import sha


def main():
    review_path=OUT/'finite-component-declaration-review-v2.json';review=json.loads(review_path.read_text());rows={r['completeSpan']:r for r in review['components'][1]['spans']};boat_path=OUT/'boat-208-profile-source.npz';boat=np.load(boat_path);tri=boat['sourceTrianglesSvgZ'];target=boat['authoredEndpoints'];tf,length=frame(*target);t=np.asarray(tf['tangent']);origin=np.asarray(tf['origin']);along=(tri[:,:,:2]-origin)@t;lower,upper=float(along.min()),float(along.max())
    def plane(span):return rows[span]['families'][0]['planeProposals'][0]['sourcePlane']
    def join(a,b):
        p,q=plane(a),plane(b);return np.linalg.solve([p['normal'],q['normal']],[p['offset'],q['offset']])
    # A boat endpoint is its actual source along plane. Its intersection with
    # the adjoining structural source sheet is shared by both declarations.
    p=plane(207);start=np.linalg.solve([p['normal'],t],[p['offset'],lower+origin@t])
    p=plane(209);end=np.linalg.solve([p['normal'],t],[p['offset'],upper+origin@t])
    joins={205:join(205,206),206:join(206,207),207:start,208:end,209:join(209,210),210:join(210,211)}
    families=[]
    for span in range(206,211):
        row=rows[span];a,b=joins[span-1],joins[span];target_frame,target_length=frame(*row['authoredEndpoints']);axis=np.asarray(target_frame['tangent']);source_length=float((b-a)@axis);assert source_length>0
        selections=row['families']
        if span==208:selections=[dict(sourceObject=7206,sourceObjectPath='Ascent_Art_B/Boat_1_BoxSternedRowboat2/StaticMeshComponent0.1048',sourceFaces=boat['originalSourceFaces'].tolist(),role='Reviewed boat silhouette; all retained actual profiles, holes and original Z remain.')]
        for index,selection in enumerate(selections):
            families.append(dict(edge=span+index*1000,completeSpan=span,sourceFrame=dict(origin=a.tolist(),tangent=axis.tolist(),normal=[-float(axis[1]),float(axis[0])]),targetFrame=target_frame,sourceAlong=[0.,source_length],targetAlong=[0.,target_length],sharedSourceJoins=[a.tolist(),b.tolist()],sharedAuthoredJoins=row['authoredEndpoints'],objects=[selection['sourceObject']],sourceObjects=[dict(sourceObjectIndex=selection['sourceObject'],path=selection['sourceObjectPath'])],reviewedSourceFaceIds=selection.get('reviewedWholeInsertFaces',selection['sourceFaces']),clipPolicy='finite-source-along-strip',sourceRole=selection['role'],heightPolicy='Original source profiles and alpha retained; no extrusion or per-height endpoint extension.'))
    report=dict(format='icarus-connected-boat-frame-declarations-v1',map='ascent',component=7,closed=False,families=families,sourceFileSha256=review['sourceFileSha256'],sourceReviewSha256=sha(review_path),boatSourcePacketSha256=sha(boat_path),scriptSha256=sha(Path(__file__)),boatSourceAlong=[lower,upper],boatTargetAlong=[0.,length],sharedBoatJoins=[dict(sourceSvg=start.tolist(),authoredSvg=target[0].tolist(),incidentSpan=207),dict(sourceSvg=end.tolist(),authoredSvg=target[1].tolist(),incidentSpan=209)],scope='Five-span bounded connected prototype206–210. The actual boat along profile is registered to authored208 and shares endpoint planes with207/209. Its distinct source-height silhouette is retained; this does not claim solid contact at every height. End poles and broader component7 attachments require source ownership checks before acceptance.',acceptance=False,productionMutation=False)
    out=OUT/'boat-connected-frame-declarations-v1.json';assert not out.exists();out.write_text(json.dumps(report,indent=2)+'\n');print(json.dumps({k:report[k] for k in ['boatSourceAlong','boatTargetAlong','sharedBoatJoins']},indent=2))

if __name__=='__main__':main()

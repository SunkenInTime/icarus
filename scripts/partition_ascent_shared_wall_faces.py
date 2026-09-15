"""Partition the exact coplanar wall faces shared by Ascent spans192 and196."""
import gzip,json
from pathlib import Path
import numpy as np
from shapely import Polygon,union_all
from build_split_normalized_wall_families import split
from native_compact_wall_profiles import sha
from prepare_ascent_connected_corners import ROOT,REV,OUT


def main():
    selection_path=OUT/'connected-source-family-selections.json';selection=json.loads(selection_path.read_text())
    proposal_path=REV/'ascent-connected-contour-proposals-v1/component-7.json.gz';component=json.loads(gzip.decompress(proposal_path.read_bytes()));rows={r['completeSpan']:r for r in component['spans']}
    # The protruding Mid arch is the intervening source assembly. These are its
    # independently reviewed front/back body planes, not target-SVG cut numbers.
    front=next(g for g in rows[193]['planes'] if g['sourceObjectIndex']==8045 and g['status']=='plane-proposal')['sourcePlane']
    back=next(g for g in rows[195]['planes'] if g['sourceObjectIndex']==8045 and g['status']=='plane-proposal')['sourcePlane']
    path=ROOT/'supplemented-v2/world/ascent/geometry.npz';raw=np.load(path);points,faces=raw['points'],raw['faces']
    affine=np.array(json.loads((ROOT/'tactical-alignment-sides-v1/ascent.json').read_text())['nativeToAttackSvg'])
    records=[];missing=extra=overlap=0.;retained=0
    for conflict in selection['finiteFragmentConflicts']:
        fid=conflict['sourceFace'];assert {int(f.split('-span-')[1].split('-')[0]) for f in conflict['families']}=={192,196}
        tri=points[faces[fid]].copy();tri[:,:2]=tri[:,:2]@affine[:,:2].T+affine[:,2]
        # Evaluate the real slanted source planes at every source vertex. Splits
        # then remain affine/barycentric even when a source plane is not axis aligned.
        signed_front=tri[:,:2]@np.array(front['normal'])-front['offset']
        signed_back=tri[:,:2]@np.array(back['normal'])-back['offset']
        data=np.column_stack((signed_front,signed_back,np.eye(3)))
        lower,remaining=split(list(data),0,0.,1)
        upper,middle=split(remaining,1,0.,1)
        pieces=[];bary_polys=[]
        for owner,poly in [(192,lower),(196,upper),('retained-between-arch-planes',middle)]:
            if len(poly)<3:continue
            bary=np.array(poly)[:,2:];polygon=Polygon(bary[:,1:]);
            if polygon.area==0:continue
            bary_polys.append(polygon);xyz=tri[0]+bary[:,1,None]*(tri[1]-tri[0])+bary[:,2,None]*(tri[2]-tri[0])
            pieces.append(dict(owner=owner,sourceBarycentrics=bary.tolist(),sourcePolygonSvgZ=xyz.tolist(),originalBarycentricArea=float(polygon.area)))
            if isinstance(owner,str):retained+=1
        union=union_all(bary_polys);expected=Polygon([[0,0],[1,0],[0,1]])
        missing=max(missing,float(expected.difference(union).area));extra=max(extra,float(union.difference(expected).area));overlap=max(overlap,sum(p.area for p in bary_polys)-union.area)
        records.append(dict(sourceFace=fid,originalSourceTriangleSvgZ=tri.tolist(),fragments=pieces))
    assert max(missing,extra,overlap)<1e-12
    report=dict(format='icarus-finite-coplanar-wall-partition-v1',map='ascent',sourceObject=8046,sourceFileSha256=sha(path),selectionSha256=sha(selection_path),sourcePlaneProposalSha256=sha(proposal_path),scriptSha256=sha(Path(__file__)),cutPlanes=dict(front193=front,back195=back),records=records,verification=dict(sourceFaces=len(records),maximumMissingOriginalBarycentricArea=missing,maximumExtraOriginalBarycentricArea=extra,maximumMultipleOwnershipOriginalBarycentricArea=overlap,retainedBetweenArchFragments=retained),policy='The intervening backing strip remains exact original source. It is not assigned to the front of the separate Mid arch. Its contacts with normalized families still require unchanged-attachment and rendering checks; partition proof alone does not certify closure.',bakeAllowed=False,productionMutation=False)
    (OUT/'shared-wall-finite-partition.json').write_text(json.dumps(report,indent=2)+'\n');print(json.dumps(report['verification'],indent=2))


if __name__=='__main__':main()

"""Declare reviewed square-corner collapse with exact source-edge height coverage."""
import json
from collections import defaultdict
from pathlib import Path
import numpy as np
from shapely import LineString, Polygon, box, union_all
from native_compact_wall_profiles import sha
from prepare_ascent_connected_corners import ROOT,OUT


def interval_shape(intervals):
    return union_all([LineString([(0.,a),(0.,b)]) for a,b in intervals if b>a])


def main():
    input_path=OUT/'column-bevel-join-review.json';review=json.loads(input_path.read_text())
    source_path=ROOT/'supplemented-v2/world/ascent/geometry.npz';raw=np.load(source_path);points,faces=raw['points'],raw['faces'];meta=json.loads(source_path.with_suffix('.json').read_text())
    affine=np.array(json.loads((ROOT/'tactical-alignment-sides-v1/ascent.json').read_text())['nativeToAttackSvg'])
    declarations=json.loads((OUT/'structural-return-declarations.json').read_text());by_span={d['completeSpan']:d for d in declarations['declarations']}
    output=[]
    for case in review['cases']:
        span=case['span'];d=by_span[span];obj=meta['objects'][case['sourceObject']];ids=np.arange(obj['firstFace'],obj['firstFace']+obj['faceCount']);edges=defaultdict(set)
        for fid,tri in zip(ids,points[faces[ids]]):
            for i,j in [(0,1),(1,2),(2,0)]:edges[tuple(sorted((tuple(tri[i]),tuple(tri[j]))))].add(int(fid))
        body_ids=set(case['bodyFaces']);body=points[faces[sorted(body_ids)]].copy();body[:,:,:2]=body[:,:,:2]@affine[:,:2].T+affine[:,2];origin,tangent=np.array(d['sourceFrame']['origin']),np.array(d['sourceFrame']['tangent'])
        body_profiles=[np.column_stack(((tri[:,:2]-origin)@tangent,tri[:,2])) for tri in body]
        allpoints=np.concatenate(body_profiles);heights=np.unique(allpoints[:,1]);left=[];right=[]
        original=union_all([Polygon(p) for p in body_profiles])
        for z in heights:
            xs=allpoints[allpoints[:,1]==z,0];left.append(float(xs.min()));right.append(float(xs.max()))
        lower,upper=max(left),min(right);assert lower<upper
        rectangle=box(lower,float(heights.min()),upper,float(heights.max()))
        missing=float(rectangle.difference(original).area)
        assert missing<1e-10
        body_min,body_max=float(heights.min()),float(heights.max())
        vertical=[r for r in case['sourceRecords'] if r['roleProposal']=='vertical-corner-bevel']
        cap_records=[];corners=[]
        for endpoint in [0,1]:
            corner=d['joins'][endpoint];corner_faces=[];neighbor_contacts=[];body_contacts=[]
            for record in vertical:
                tri=np.array(record['sourceTriangleNative']);svg=tri[:,:2]@affine[:,:2].T+affine[:,2];along=float(((svg-origin)@tangent).mean());which=int(along>(lower+upper)/2)
                if which!=endpoint:continue
                corner_faces.append(record['sourceFace'])
                for edge,owners in edges.items():
                    if record['sourceFace'] not in owners:continue
                    for owner in owners-{record['sourceFace']}:
                        if owner in {r['sourceFace'] for r in vertical}:continue
                        other=points[faces[owner]];normal=np.cross(other[1]-other[0],other[2]-other[0]);normal/=np.linalg.norm(normal)
                        if abs(normal[2])>=.01:continue
                        contact=dict(sourceFace=owner,bevelFace=record['sourceFace'],sourceEdgeNative=[list(p) for p in edge],originalZInterval=[min(p[2] for p in edge),max(p[2] for p in edge)])
                        (body_contacts if owner in body_ids else neighbor_contacts).append(contact)
                cap_records.append(dict(sourceFace=record['sourceFace'],sourceBarycentrics=np.eye(3).tolist(),mapping='collapse-XY-to-authored-corner-preserve-each-original-Z',targetSvg=corner['targetSvg'],originalSourceTriangle=record['sourceTriangleNative'],originalZInterval=record['sourceZBounds'],corner=endpoint,UVMaterialPolicy='Keep original source face and barycentrics; no material/alpha replacement or filled polygon.'))
            expected=interval_shape([r['originalZInterval'] for r in cap_records if r['corner']==endpoint])
            body_coverage=interval_shape([c['originalZInterval'] for c in body_contacts]);neighbor_coverage=interval_shape([c['originalZInterval'] for c in neighbor_contacts])
            missing_body=float(expected.difference(body_coverage).length);missing_neighbor=float(expected.difference(neighbor_coverage).length)
            assert missing_body<1e-10 and missing_neighbor<1e-10
            corners.append(dict(endpoint=endpoint,targetSvg=corner['targetSvg'],collapsedSourceFaces=corner_faces,bodySharedSourceEdges=body_contacts,neighborSharedSourceEdges=neighbor_contacts,coverageProof=dict(missingBodyEdgeHeightMeters=missing_body,missingNeighborEdgeHeightMeters=missing_neighbor),requiredMappingContract='All endpoints on these exact incident shared source edges map to this authored corner with original Z unchanged. Incident body source intervals must clamp their entire corner seam to the same endpoint; no nearest-edge assignment.'))
        top_bottom=[r for r in case['sourceRecords'] if r['roleProposal']=='top-or-bottom-bevel']
        output.append(dict(span=span,sourceObject=case['sourceObject'],bodyFaces=sorted(body_ids),bodySourceAlongInterval=[lower,upper],targetAlong=d['targetAlong'],bodyOriginalZInterval=[body_min,body_max],bodyCropCoverage=dict(missingOriginalProfileAreaSvgMeters=missing,policy='Crop to the common source body width present at every original body height; endpoint-clamped remainder keeps original Z and must be covered at the corner. This is the explicit square-SVG abstraction, not a source-shape equivalence claim.'),cornerContracts=corners,collapsedVerticalBevels=cap_records,preservedTopBottomBevels=[dict(sourceFace=r['sourceFace'],sourceBarycentrics=np.eye(3).tolist(),originalSourceTriangle=r['sourceTriangleNative'],mapping='ordinary-host-along-profile-with-source-Z; do-not-collapse-to-corner',originalZInterval=r['sourceZBounds']) for r in top_bottom],bakeAllowed=False,pending='Apply these contracts to both incident connected families, then run source partition and unchanged-attachment mapping checks.'))
    report=dict(format='icarus-explicit-column-square-corner-v1',sourceFileSha256=sha(source_path),bevelReviewSha256=sha(input_path),scriptSha256=sha(Path(__file__)),declarations=output,productionMutation=False,scope='Exact raw-source shared-edge and height-coverage proof for the approved corner abstraction. No candidate/world/renderer acceptance.')
    (OUT/'column-corner-collapse-declarations.json').write_text(json.dumps(report,indent=2)+'\n');print(json.dumps([dict(span=d['span'],bodyCrop=d['bodySourceAlongInterval'],coverage=d['bodyCropCoverage']['missingOriginalProfileAreaSvgMeters'],corners=[c['coverageProof'] for c in d['cornerContracts']]) for d in output],indent=2))


if __name__=='__main__':main()

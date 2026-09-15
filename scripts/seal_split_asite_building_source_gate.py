"""Bind the accepted finite A-site source correction before cumulative staging."""
import ast
import gzip
import hashlib
import json
from fractions import Fraction as F
from pathlib import Path

import numpy as np

from verify_region_contacts_exact import exact_line_intervals
from verify_region_mapping import verify_rank_one_declarations

ROOT=Path('E:/IcarusWorldAudit/2026-09-06')
REV=ROOT/'tactical-visibility-revision'
OUT=REV/'split-asite-building-connected-proposal-v6'


def sha(path):return hashlib.sha256(path.read_bytes()).hexdigest()
def read(path):return json.loads(path.read_text())


def main():
    gate=OUT/'source-staging-gate.json';assert not gate.exists()
    declaration=OUT/'region-declaration.json';family=read(declaration);digest=sha(declaration)
    contact=read(OUT/'continuous-source-review.json');attachment=read(OUT/'source-attachment-review.json')
    topology=read(OUT/'topology-review.json');along=read(OUT/'old17-along-continuity-review.json')
    partition_dir=REV/'split-asite-building-raw-partition-v6';partition=read(partition_dir/'partition-review.json')
    rays_path=REV/'split-asite-building-standing17-hybrid-v6/first-hit-controls.json';rays=read(rays_path)
    for report in [contact,attachment,partition,rays]:assert report['declarationSha256']==digest
    scripts=Path('scripts')
    for report,name in [(contact,'review_split_asite_building_region.py'),(attachment,'review_split_asite_building_attachments.py'),(partition,'partition_split_asite_building_source.py'),(rays,'audit_split_asite_building_top_controls.py'),(topology,'extend_split_asite_building_left_shell.py')]:
        assert report['scriptSha256']==sha(scripts/name),(name,'script changed after evidence')
    raw_path=ROOT/'supplemented-v2/world/split/geometry.npz';raw=np.load(raw_path);meta=read(raw_path.with_suffix('.json'))
    for report in [contact,attachment,partition,rays]:assert report['sourceGeometrySha256']==sha(raw_path)
    assert sha(partition_dir/'raw-source-fragments.npz')==partition['fragmentFileSha256']
    assert len(contact['contacts'])==21 and all(x['continuousNormalContact'] for x in contact['contacts'])
    assert max(x['maximumNormalErrorSvg'] for x in contact['contacts'])<1e-10
    assert contact['upperFieldInheritance']['maximumErrorSvg']<1e-10
    assert along['maximumOld17AlongErrorSvg']<1e-10
    assert topology['topology']['sourceCellOverlapSvgSquared']==0
    assert topology['topology']['maximumBoundaryDisplayErrorSvg']==0
    ranks=verify_rank_one_declarations(family)
    assert partition['rawSourceFaces']==partition['reviewedSourceFaces']==4627
    assert partition['sourcePartition']['maximumRelativeCoverageError']<1e-9
    assert partition['sourcePartition']['maximumRelativeOverlap']<1e-9
    assert not partition['unaffectedOutsideParentFaces'] and partition['outsideFieldPolygons']==0
    assert not any(partition['protectedDistantFamilyRawParentIntersection'].values())
    fragments=np.load(partition_dir/'raw-source-fragments.npz');parents=fragments['sourceFaces'];bary=fragments['barycentrics']
    assert set(parents)==set(family['reviewedSourceFaces'])
    xyz=raw['points'][raw['faces'][parents]]
    z_error=float(abs(fragments['trianglesNativeSourceZ'][:,:,2]-np.einsum('nij,nj->ni',bary,xyz[:,:,2])).max())
    uv_error=float(abs(fragments['uvs']-np.einsum('nij,njk->nik',bary,raw['uvs'][parents])).max())
    assert z_error<1e-10 and uv_error==0
    np.testing.assert_array_equal(fragments['materialIndices'],raw['material_indices'][parents])
    assert attachment['sourceFaceCount']==4627 and attachment['retainedFaceCount']==4615
    retained=set(np.load(REV/'full-height-input-v1/split/source-correspondence.npz')['sourceFaces'].tolist())
    assert set(attachment['omittedOriginalFaceIds'])==set(family['reviewedSourceFaces'])-retained
    positive={(p['detailObject'],p['parentObject']) for p in attachment['attachmentPairs'] if p['positiveInteriorIntersectionCount']}
    required={(429,5857),(429,5853),(447,5849),(430,5857),(430,5849),*[(i,5849) for i in range(438,446)]}
    assert required<=positive

    # Preserve legacy17 literally. The new family consumes both complete source
    # instances before17;7107 never qualifies for the new family.
    base_path=REV/'split-wall-family-normalized-candidate-v30-cached-v1/bindings.json'
    base=read(base_path);old=next(f for f in base['families'] if f['edge']==17)
    assert old['objects']==[7107,429,5857] and 7107 not in family['objects']
    wp=REV/'display-warps-v1/split.display-warp.json.gz';w=json.loads(gzip.decompress(wp.read_bytes()))
    assert sha(wp)==partition['warpSha256']
    matrix=np.column_stack((w['projection']['axisU'],w['projection']['axisV']));origin=np.array(w['projection']['origin'])
    meshes={};source_roles=[]
    for oid in [7107,429,5857]:
        ob=meta['objects'][oid];ids=np.arange(ob['firstFace'],ob['firstFace']+ob['faceCount'])
        tri=raw['points'][raw['faces'][ids]].astype(float);tri[:,:,:2]=tri[:,:,:2]@matrix.T+origin;meshes[oid]=tri
        if oid!=7107:
            assert set(ids)<=set(family['reviewedSourceFaces'])
            assert (tri[:,:,:2]>=family['box'][:2]).all() and (tri[:,:,:2]<=family['box'][2:]).all()
        source_roles.append(dict(object=oid,rawFaces=ids.tolist(),boundsSvgZ=[tri.reshape(-1,3).min(0).tolist(),tri.reshape(-1,3).max(0).tolist()],newFieldMember=oid in family['objects']))
    overlap=sorted(set(old['originalSourceFaces'])&set(family['reviewedSourceFaces']));assert len(overlap)==139
    source_set=set(family['reviewedSourceFaces'])
    assert all(not(set(f['originalSourceFaces'])&source_set) for f in base['families'] if f['edge']!=17)

    # The real two source instances overlap7107 near its finite right end.
    # Check the full rectangular overlap strip in every declared affine cell
    # with exact rational clipping, not selected samples.
    strip=[float(meshes[429][:,:,0].min()),float(meshes[429][:,:,1].min()),float(meshes[7107][:,:,0].max()),old['box'][3]]
    vertices=np.array(family['sourceVerticesSvg']);targets=np.array(family['targetVerticesSvg']);cells=np.array(family['triangles'])
    s0,s1=map(F,old['sourceAlong']);t0,t1=map(F,old['targetAlong']);max_error=F(0);pieces=0
    for ci,indices in enumerate(cells):
        q=targets[indices]
        if ci in ranks:
            rank=ranks[ci];a,b=rank['endpoints'];q=a+rank['parameters'][:,None]*(b-a)
        rows=[[F(float(v)) for v in [*p,*target]] for p,target in zip(vertices[indices],q)]
        for axis,bound,sign in [(0,strip[0],1),(1,strip[1],1),(0,strip[2],-1),(1,strip[3],-1)]:
            if not rows:break
            clipped=[];bound=F(bound)
            for a,b in zip(rows,rows[1:]+rows[:1]):
                av=(a[axis]-bound)*sign;bv=(b[axis]-bound)*sign
                if av>=0:clipped.append(a)
                if (av>=0)!=(bv>=0):
                    t=av/(av-bv);clipped.append([x+t*(y-x) for x,y in zip(a,b)])
            rows=clipped
        if len(rows)<3:continue
        pieces+=1
        for p in rows:
            expected=t0+(p[0]-s0)*(t1-t0)/(s1-s0)
            max_error=max(max_error,abs(p[2]-expected),abs(p[3]-F(old['fixed'])))
    assert pieces and float(max_error)<1e-10
    # Exact line union independently ensures no cell-coverage hole crosses the strip.
    for y in [strip[1],strip[3]]:exact_line_intervals(family,[[strip[0],y],[strip[2],y]])

    assert len(rays['fixtures'])==len(rays['records'])==4
    fixtures={f['id']:f for f in rays['fixtures']};ray_checks=[]
    for row in rays['records']:
        fixture=fixtures[row['originId']];hit=row['proposedHybridHit'];prior=row['v29OriginalHeightHit']
        assert fixture['eyeZ'] in [3.75,3.85] and row['queryStart'][2]==fixture['eyeZ']
        assert fixture['sourceFloorProbe']['point'][2]==2.0
        assert any(a['parentBoundaryMarginMeters']>.15 and a['fiveVerticalBodyProbesClear'] for a in fixture['sourceStandingEvidence'])
        assert hit['sourceObject']==5857 and hit['rawSourceFace']==1862034 and hit['kind']=='proposed-source-section'
        assert prior['rawSourceFace']==1862113 and prior['distanceMeters']<hit['distanceMeters']
        point=np.array(hit['displayedHitSvg']);assert abs(point[1]-56.809)<1e-10
        errors=[]
        for side in row['sideReceiver']:
            assert side['originPainted'] and not side['targetPainted'] and len(side['paintedPathSegments'])==1
            target=point if side['side']=='attack' else np.array(w['attackToDefenseSvg']['origin'])-point
            error=float(np.linalg.norm(target-np.array(side['paintedPathSegments'][0][-1])));assert error<1e-10;errors.append(error)
        ray_checks.append(dict(originId=row['originId'],sourceEyeZ=fixture['eyeZ'],sourceFloorZ=2.0,oldDistanceMeters=prior['distanceMeters'],newDistanceMeters=hit['distanceMeters'],displayedHitSvg=point.tolist(),maximumReceiverEndpointErrorSvg=max(errors)))
    assert {(tuple(f['startSvg']),f['eyeZ']) for f in fixtures.values()}=={((x,60.809),z) for x in [405.755,405.605] for z in [3.75,3.85]}

    # Bind the current local dependency closure used by the reviewed scripts.
    queue=['seal_split_asite_building_source_gate','extend_split_asite_building_left_shell','review_split_asite_building_region','review_split_asite_building_attachments','partition_split_asite_building_source','audit_split_asite_building_top_controls']
    helpers={}
    while queue:
        name=queue.pop();path=scripts/(name+'.py')
        if name in helpers or not path.exists():continue
        helpers[name]=dict(path=str(path.resolve()),sha256=sha(path))
        for node in ast.walk(ast.parse(path.read_text())):
            if isinstance(node,ast.Import):queue.extend(a.name.split('.')[0] for a in node.names)
            elif isinstance(node,ast.ImportFrom) and node.module:queue.append(node.module.split('.')[0])
    evidence=[declaration,OUT/'replay-seal.json',OUT/'continuous-source-review.json',OUT/'topology-review.json',OUT/'source-attachment-review.json',OUT/'old17-along-continuity-review.json',partition_dir/'partition-review.json',partition_dir/'raw-source-fragments.npz',rays_path,base_path,wp,raw_path]
    report=dict(passed=True,scope='Accepted bounded A-site source correction for cumulative staging. Cumulative oracle and actual rendered cones remain required.',declaration=dict(path=str(declaration),sha256=digest,edge=200018),
        stagingContract=dict(operation='Insert200018 before an unchanged legacy17 declaration. Do not remove17 or change its objects, box, along mapping, fixed coordinate or other fields.',preservedLegacyEdge=17,preservedLegacyDeclaration=old,newFieldSourceBox=family['box'],supersededLegacyRawParents=overlap,sourceRoles=source_roles,otherPriorFamilyRawOverlap=0),
        continuousInterface=dict(sourceOverlapStripSvg=strip,exactClippedAffinePieces=pieces,maximumLegacy17FieldErrorSvg=float(max_error),meaning='Complete overlap strip shares the same old17 along mapping and Y56.809. The untouched7107 source remains on old17.'),
        contacts=len(contact['contacts']),maximumContactErrorSvg=max(x['maximumNormalErrorSvg'] for x in contact['contacts']),partition=partition['sourcePartition'],sourceFaces=4627,retainedSourceFaces=4615,maximumSourceZErrorMeters=z_error,maximumOriginalUvInterpolationError=uv_error,requiredPositiveAttachmentPairs=sorted(required),standingCases=ray_checks,
        evidence=[dict(path=str(p),sha256=sha(p)) for p in evidence],currentHelpers=helpers,productionMutation=False,limits=['Four frozen standing17 rays are source-section diagnostics, not cumulative application captures.','Original material omissions stay unchanged; no map-wide transparency or floor-policy claim.','Finite source heights, roofs and openings must remain in the cumulative partition and rendering.'])
    gate.write_text(json.dumps(report,indent=2)+'\n');print(json.dumps(dict(gate=str(gate),sha256=sha(gate),helpers=len(helpers),interfaceError=float(max_error),standingCases=len(ray_checks))))


if __name__=='__main__':main()

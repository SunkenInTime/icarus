"""Resolve authored contact points against original source depth-fiber segments."""
import argparse,json
from pathlib import Path
import numpy as np
import shapely
from native_reference_cast import NativeReferenceModel
from native_compact_wall_profiles import sha
from prepare_ascent_connected_corners import ROOT,REV


def main(folder,positive_controls=False):
    folder=Path(folder);binding=json.loads((folder/'bindings.json').read_text());family=binding['families'][0];s=np.array(family['sourceVerticesSvg']);t=np.array(family['targetVerticesSvg']);cells=np.array(family['triangles']);st=s[cells];tt=t[cells];envelopes=shapely.box(tt[:,:,0].min(1),tt[:,:,1].min(1),tt[:,:,0].max(1),tt[:,:,1].max(1));tree=shapely.STRtree(envelopes);queries=json.loads((folder/'independent-junction-rays.json').read_text());source_path=Path(binding['sourceBackup']);source=NativeReferenceModel(source_path,REV/'native-rounded-profile-oracle-build/build/Release/rounded_profile_oracle.dll');c2f=np.load(REV/'global-ground-complete-v2/ascent/correspondence.npz')['sourceFaces'];f2o=np.load(REV/'full-height-input-v1/ascent/source-correspondence.npz')['sourceFaces'];c2o=f2o[c2f];meta=json.loads((ROOT/'supplemented-v2/world/ascent/geometry.json').read_text());starts=np.array([o['firstFace'] for o in meta['objects']]);aff=np.array(json.loads((ROOT/'tactical-alignment-sides-v1/ascent.json').read_text())['nativeToAttackSvg']);inv=np.linalg.inv(aff[:,:2]);rows=[]
    for row in queries['records']:
        statuses=['passed-authored-wall','no-candidate-hit']
        if positive_controls:statuses.append('exact-contact')
        if row['status'] not in statuses:continue
        p=np.array(row['expectedContactSvg']);z=row['relativeEyeHeightMeters'];fibers=[];point_cells=[];hits=[]
        for cell in tree.query(shapely.Point(p).buffer(1e-9)):
            q=tt[cell];basis=q[1:]-q[0];length=np.linalg.norm(basis,axis=1);axis=basis[np.argmax(length)]
            if np.linalg.norm(axis)<1e-12:point_cells.append(int(cell));continue
            axis/=np.linalg.norm(axis);normal=np.array([-axis[1],axis[0]])
            if np.max(abs((q-q[0])@normal))>1e-9:continue
            if abs((p-q[0])@normal)>1e-8:continue
            values=(q-p)@axis;points=[]
            for i,j in [(0,1),(1,2),(2,0)]:
                if abs(values[i])<1e-12:points.append(st[cell,i])
                if values[i]*values[j]<0:points.append(st[cell,i]+(st[cell,j]-st[cell,i])*values[i]/(values[i]-values[j]))
            if len(points)<2:continue
            points=np.array(points);dist=np.linalg.norm(points[:,None]-points[None],axis=2);i,j=np.unravel_index(np.argmax(dist),dist.shape)
            if dist[i,j]<1e-10:continue
            xy=(points[[i,j]]-aff[:,2])@inv.T;segment=np.column_stack((xy,[z,z]));hit=source.cast(*segment,min_distance=0,end_padding=0,end_inclusive=True);fibers.append(dict(regionCell=int(cell),sourceSegment=segment.tolist()))
            if hit:
                fid=int(c2o[hit['face']]);obj=int(np.searchsorted(starts,fid,side='right')-1);box=np.asarray(family['box']);hitpoint=segment[0]+(segment[1]-segment[0])*hit['distanceMeters']/np.linalg.norm(segment[1]-segment[0]);hitsvg=hitpoint[:2]@aff[:,:2].T+aff[:,2];in_region=bool(np.all(hitsvg>=box[:2]) and np.all(hitsvg<=box[2:]));reviewed=fid in family['reviewedSourceFaceIds'];hits.append(dict(regionCell=int(cell),sourceControlFace=hit['face'],originalSourceFace=fid,sourceObject=obj,sourcePath=meta['objects'][obj]['path'],belongsToReviewedFamily=reviewed,insideFiniteRegion=in_region,qualifiesAsFamilyContact=reviewed and in_region,hit=hit))
        family_hit=any(h['qualifiesAsFamilyContact'] for h in hits)
        rows.append(dict(query=row,nonzeroSourceDepthFibers=fibers,sourceHits=hits,sourceProfileHasOpaqueContact=bool(hits),reviewedFamilyHasOpaqueContact=family_hit,unresolvedPointOnlyCells=point_cells,interpretation='Reviewed source family has an opaque contact in the declared finite depth fiber.' if family_hit else 'No reviewed-family contact certified by these fibers; point-only, rank-two and unrelated-source cases require separate checks.'))
    report=dict(format='icarus-source-depth-fiber-contact-control-v1',sourcePackSha256=sha(source_path),candidatePackSha256=queries['candidatePackSha256'],declarationSha256=sha(folder/'bindings.json'),scriptSha256=sha(Path(__file__)),rows=rows,scope='Exact unchanged source triangle/alpha casts over the nonzero source segments collapsed to each authored contact point. Zero-dimensional fibers and unrelated rank-two cells are not certified by this bounded diagnostic.',productionMutation=False)
    filename='source-contact-fiber-positive-controls.json' if positive_controls else 'source-contact-fiber-review.json'
    (folder/filename).write_text(json.dumps(report,indent=2)+'\n');print('queries',len(rows),'with source contact',sum(r['sourceProfileHasOpaqueContact'] for r in rows),'no source contact',sum(not r['sourceProfileHasOpaqueContact'] for r in rows))


if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('candidate');p.add_argument('--positive-controls',action='store_true');a=p.parse_args();main(a.candidate,a.positive_controls)


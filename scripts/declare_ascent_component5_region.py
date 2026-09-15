"""One shared monotone field for the reviewed Ascent courtyard assemblies."""
import argparse,gzip,json
from pathlib import Path
import numpy as np
import shapely
from shapely import Polygon
from native_compact_wall_profiles import sha
from prepare_ascent_connected_corners import ROOT,REV,OUT
from tactical_alignment_composite import explicit_warp
from verify_region_mapping import verify_region_topology
from authored_wall_profile_cells import partition_linear


def main(version):
    prior_path=OUT/'component5-compiled-frames-v1.json';prior=json.loads(prior_path.read_text());rawpath=ROOT/'supplemented-v2/world/ascent/geometry.npz';a=np.load(rawpath);points,faces=a['points'],a['faces'];meta=json.loads(rawpath.with_suffix('.json').read_text());aff=np.array(json.loads((ROOT/'tactical-alignment-sides-v1/ascent.json').read_text())['nativeToAttackSvg']);wpath=REV/'display-warps-v1/ascent.display-warp.json.gz';w=json.loads(gzip.decompress(wpath.read_bytes()));wp=np.array(w['sourceNativeMeters']).reshape(-1,2)@aff[:,:2].T+aff[:,2];wt=np.array(w['targetAttackSvg']).reshape(-1,2);forward=explicit_warp(wp,wt-wp,np.array(w['triangles']).reshape(-1,3))
    mounted={857,858,*range(1041,1049)} if version>=6 else set()
    if version>=7:mounted.update([6571,769])
    bands=[{},{}];objects=sorted({i for f in prior['families'] for i in f['objects']}|({6501} if version>=3 else set())|mounted);all_ids=np.concatenate([np.arange(meta['objects'][i]['firstFace'],meta['objects'][i]['firstFace']+meta['objects'][i]['faceCount']) for i in objects]);tri=points[faces[all_ids]].copy();tri[:,:,:2]=tri[:,:,:2]@aff[:,:2].T+aff[:,2]
    for f in prior['families']:
        tangent=np.array(f['targetFrame']['tangent'])
        if abs(tangent).min()>1e-10:continue
        normal_axis=int(np.argmin(abs(tangent)));target=float(f['targetFrame']['origin'][normal_axis]);xyz=points[faces[f['reviewedSourceFaceIds']]];xy=xyz[:,:,:2]@aff[:,:2].T+aff[:,2];bounds=[float(xy[:,:,normal_axis].min()),float(xy[:,:,normal_axis].max())];b=bands[normal_axis].setdefault(target,dict(lower=bounds[0],upper=bounds[1],spans=[],sourceFaces=[]));b['lower']=min(b['lower'],bounds[0]);b['upper']=max(b['upper'],bounds[1]);b['spans'].append(f['completeSpan']);b['sourceFaces'].extend(f['reviewedSourceFaceIds'])
    # Source-reviewed end columns and front gate columns include protruding
    # base/capital relief. Preserve their full source height, with the same
    # wall depth band used at every height, rather than leaving caps behind.
    for obj in [667,668,669,670]:
        ob=meta['objects'][obj];xyz=points[faces[ob['firstFace']:ob['firstFace']+ob['faceCount']]];xy=xyz[:,:,:2]@aff[:,:2].T+aff[:,2]
        bands[1][340.5]['upper']=max(bands[1][340.5]['upper'],float(xy[:,:,1].max()))
        if obj==667:
            bands[0][178.]['upper']=max(bands[0][178.]['upper'],float(xy[:,:,0].max()));bands[1][337.5]['lower']=min(bands[1][337.5]['lower'],float(xy[:,:,1].min()))
        if obj==670:bands[0][132.]['lower']=min(bands[0][132.]['lower'],float(xy[:,:,0].min()))
    # The diagonal source return is exactly tied to both incident body joins.
    for left in [144,145]:
        join=next(j for j in prior['joins'] if j['leftSpan']==left)
        for axis,(value,target) in enumerate(zip(join['sourceSvg'],join['targetSvg'])):
            if float(target) not in bands[axis]:bands[axis][float(target)]=dict(lower=float(value),upper=float(value),spans=[144,145,146],sourceFaces=[],role='Exact diagonal join datum')
    mounted_diagonal_ids=[]
    if version>=6:
        # Full source-reviewed static door frames and their four masked sheets
        # share the diagonal depth mapping. No ignored glass is reintroduced.
        for oid in [857,858,*range(1041,1045)]:
            obj=meta['objects'][oid];ids=list(range(obj['firstFace'],obj['firstFace']+obj['faceCount']));mounted_diagonal_ids.extend(ids)
        xy=points[faces[mounted_diagonal_ids]][:,:,:2]@aff[:,:2].T+aff[:,2]
        bands[0][207.]['lower']=min(bands[0][207.]['lower'],float(xy[:,:,0].min()))
        bands[0][214.]['upper']=max(bands[0][214.]['upper'],float(xy[:,:,0].max()))
        bands[1][267.5]['lower']=min(bands[1][267.5]['lower'],float(xy[:,:,1].min()))
        bands[1][274.5]['upper']=max(bands[1][274.5]['upper'],float(xy[:,:,1].max()))
        for oid in range(1045,1049):
            obj=meta['objects'][oid];ids=list(range(obj['firstFace'],obj['firstFace']+obj['faceCount']));xy=points[faces[ids]][:,:,:2]@aff[:,:2].T+aff[:,2]
            band=bands[1][265.];band['lower']=min(band['lower'],float(xy[:,:,1].min()));band['upper']=max(band['upper'],float(xy[:,:,1].max()));band['sourceFaces'].extend(ids)
    if version>=7:
        for oid in [6571,769]:
            obj=meta['objects'][oid];ids=list(range(obj['firstFace'],obj['firstFace']+obj['faceCount']));xy=points[faces[ids]][:,:,:2]@aff[:,:2].T+aff[:,2]
            band=bands[0][214.];band['lower']=min(band['lower'],float(xy[:,:,0].min()));band['upper']=max(band['upper'],float(xy[:,:,0].max()));band['sourceFaces'].extend(ids)
    if version>=8:
        for ids,target_x in [(list(range(2964376,2964400)),171.5),(list(range(2964400,2964424)),169.5)]:
            xy=points[faces[ids]][:,:,:2]@aff[:,:2].T+aff[:,2];band=bands[0][target_x]
            band['lower']=min(band['lower'],float(xy[:,:,0].min()));band['upper']=max(band['upper'],float(xy[:,:,0].max()));band['sourceFaces'].extend(ids)
    knots=[];mapped=[]
    for axis in [0,1]:
        coordinates=[];targets=[];last=-np.inf
        for target,b in sorted(bands[axis].items()):
            assert b['lower']>last,('Overlapping distinct authored coordinate bands',axis,target,b,last)
            for value in sorted(set([b['lower'],b['upper']])):coordinates.append(value);targets.append(target)
            last=b['upper']
        coordinates=np.array(coordinates);targets=np.array(targets)
        # Outer collars surround the finite courtyard component, independent of
        # the source object's remote geometry. Source beyond them stays intact.
        coordinates=np.r_[coordinates[0]-4,coordinates[0]-2,coordinates,coordinates[-1]+2,coordinates[-1]+4]
        targets=np.r_[coordinates[:2],targets,coordinates[-2:]]
        assert np.all(np.diff(targets)>=0)
        knots.append(coordinates);mapped.append(targets)
    xs,ys=knots;nx=len(xs);grid=np.array([[x,y] for y in ys for x in xs]);desired=np.array([[tx,ty] for ty in mapped[1] for tx in mapped[0]])
    # Finite outer edge is exactly existing display W. Refine only cells touching
    # that boundary at W edges, so an intermediate W kink cannot leave a seam.
    outer=(np.isin(grid[:,0],[xs[0],xs[-1]])|np.isin(grid[:,1],[ys[0],ys[-1]]));outer_display=forward.apply(grid[outer]);refine_boundary=not np.array_equal(outer_display,grid[outer]);desired[outer]=outer_display;base=[]
    for row in range(len(ys)-1):
        for col in range(nx-1):
            q=row*nx+col;base.extend([[q,q+1,q+nx+1],[q,q+nx+1,q+nx]])
    diagonal=None
    if version>=4:
        d=next(f for f in prior['families'] if f['completeSpan']==145);diagonal_ids=d['reviewedSourceFaceIds']+mounted_diagonal_ids;xy=points[faces[diagonal_ids]][:,:,:2]@aff[:,:2].T+aff[:,2];values=list((xy[:,:,1]-xy[:,:,0]).reshape(-1));patch=np.array([bands[0][207.]['lower'],bands[1][267.5]['lower'],bands[0][214.]['upper'],bands[1][274.5]['upper']]);constant=60.5
        # Include the current field's preimage of the authored diagonal in its
        # source depth band. This makes the correction monotone through both the
        # source wall and its numerical/relief registration displacement.
        for ids in base:
            for i,j in zip(ids,np.roll(ids,-1)):
                av=desired[i,1]-desired[i,0]-constant;bv=desired[j,1]-desired[j,0]-constant
                samples=[]
                if av==0:samples.append(grid[i])
                if av*bv<0:samples.append(grid[i]+(grid[j]-grid[i])*av/(av-bv))
                for q in samples:
                    if np.all(q>=patch[:2]-1e-9) and np.all(q<=patch[2:]+1e-9):values.append(float(q[1]-q[0]))
        diagonal=dict(sourceDifferenceBand=[min(values),max(values)],sourcePatch=patch.tolist(),targetDifference=constant,sourceFaces=diagonal_ids,targetEndpoints=[[207.,267.5],[214.,274.5]])
    source=[];target=[];cells=[];lookup={};wpolys=shapely.polygons(wp[np.array(w['triangles']).reshape(-1,3)]);tree=shapely.STRtree(wpolys)
    for ids in base:
        source_tri=grid[ids];target_tri=desired[ids];parts=[Polygon(source_tri)]
        split_diagonal=diagonal is not None
        if diagonal and version>=5:
            patch=np.asarray(diagonal['sourcePatch'])
            split_diagonal=bool(np.all(source_tri.mean(0)>patch[:2]) and np.all(source_tri.mean(0)<patch[2:]))
        if split_diagonal:parts=[Polygon(part) for part in partition_linear(source_tri,np.zeros(2),np.array([-1.,1.]),diagonal['sourceDifferenceBand'])]
        if refine_boundary and outer[ids].any():parts=[part.intersection(wpolys[c]) for part in parts for c in tree.query(part)]
        for part in parts:
            if part.geom_type!='Polygon' or part.area<=1e-16:continue
            coords=np.array(part.exterior.coords)[:-1];uv=np.linalg.solve(np.stack((source_tri[1]-source_tri[0],source_tri[2]-source_tri[0]),axis=1),(coords-source_tri[0]).T).T;targets=target_tri[0]+uv@(target_tri[1:]-target_tri[0]);on_outer=(np.isclose(coords[:,0],xs[0],atol=1e-9,rtol=0)|np.isclose(coords[:,0],xs[-1],atol=1e-9,rtol=0)|np.isclose(coords[:,1],ys[0],atol=1e-9,rtol=0)|np.isclose(coords[:,1],ys[-1],atol=1e-9,rtol=0));targets[on_outer]=forward.apply(coords[on_outer]);indices=[]
            if diagonal:
                patch=np.array(diagonal['sourcePatch']);lower,upper=diagonal['sourceDifferenceBand'];dif=coords[:,1]-coords[:,0];inside=((coords>=patch[:2]-1e-9)&(coords<=patch[2:]+1e-9)).all(1)&(dif>=lower-1e-9)&(dif<=upper+1e-9)
                for i in np.flatnonzero(inside):
                    if abs(coords[i,0]-patch[0])<1e-9 or abs(coords[i,1]-patch[1])<1e-9:targets[i]=[207.,267.5]
                    elif abs(coords[i,0]-patch[2])<1e-9 or abs(coords[i,1]-patch[3])<1e-9:targets[i]=[214.,274.5]
                    else:
                        x=float(np.clip((targets[i,0]+targets[i,1]-60.5)*.5,207.,214.));y=x+60.5;targets[i]=[y-60.5,y]
            for p,q in zip(coords,targets):
                key=tuple(np.rint(p*1e9).astype(np.int64))
                if key in lookup:
                    i=lookup[key];assert np.linalg.norm(np.array(source[i])-p)<2e-9 and np.linalg.norm(np.array(target[i])-q)<2e-8
                else:i=len(source);lookup[key]=i;source.append(p.tolist());target.append(q.tolist())
                indices.append(i)
            for j in range(1,len(indices)-1):
                if len(set([indices[0],indices[j],indices[j+1]]))==3:cells.append([indices[0],indices[j],indices[j+1]])
    if version>=5:
        # A finite patch introduces vertices on neighboring source cell edges.
        # Insert those exact stored vertices into both incident boundaries;
        # unrelated cells need no extension of the diagonal's infinite lines.
        sp=np.asarray(source);tp=np.asarray(target);noded=[]
        for ids in cells:
            boundary=[]
            for a,b in zip(ids,np.roll(ids,-1)):
                delta=sp[b]-sp[a];length=np.linalg.norm(delta);u=(sp-sp[a])@delta/(length*length)
                distance=np.abs((sp[:,0]-sp[a,0])*delta[1]-(sp[:,1]-sp[a,1])*delta[0])/length
                interior=np.flatnonzero((u>1e-12)&(u<1-1e-12)&(distance<1e-10))
                boundary.append(int(a));boundary.extend(interior[np.argsort(u[interior])].tolist())
            if len(boundary)==3:noded.append(ids);continue
            center=len(source);source.append(sp[ids].mean(0).tolist());target.append(tp[ids].mean(0).tolist())
            noded.extend([[center,a,b] for a,b in zip(boundary,boundary[1:]+boundary[:1])])
        cells=noded
    family=dict(edge=205005,mappingType='piecewise-affine-region-v1',completeSpans=list(range(136,153)),sourceVerticesSvg=source,targetVerticesSvg=target,triangles=cells,objects=objects,sourceObjects=[dict(sourceObjectIndex=i,path=meta['objects'][i]['path']) for i in objects],reviewedSourceFaceIds=all_ids.tolist(),box=[xs[0],ys[0],xs[-1],ys[-1]],identityOuterBoundary=True,sourceCoordinateBands=bands,role='Reviewed connected column, gate, courtyard backing and return/roof assemblies share one finite XY field. Original Z, source-face identity and alpha retained; no height extrusion. Remote source geometry outside the component collar is untouched.',reviewedAuthoredSpans=[dict(completeSpan=f['completeSpan'],startSvg=f['sharedAuthoredJoins'][0],endSvg=f['sharedAuthoredJoins'][1]) for f in prior['families'] if f['edge']<1000])
    try:topology=verify_region_topology(family,forward)
    except AssertionError:
        (OUT/'component5-region-rejected-diagnostic.json').write_text(json.dumps(family,indent=2)+'\n');raise
    if diagonal:family['diagonal145DepthBand']=diagonal
    report=dict(format='icarus-connected-region-declarations-v1',map='ascent',component=5,families=[family],sourceFileSha256=sha(rawpath),sourceFrameDeclarationSha256=sha(prior_path),displayWarpSha256=sha(wpath),scriptSha256=sha(Path(__file__)),topology=topology,productionMutation=False,acceptance=False,scope='Shared connected attachment region candidate; independent source partition, contact, ray and rendered audits gate acceptance.')
    if version>=3:report['roofAttachmentReview']=dict(sourceObject=6501,sourceFaces=list(range(meta['objects'][6501]['firstFace'],meta['objects'][6501]['firstFace']+meta['objects'][6501]['faceCount'])),sourceReviewImage=str(REV/'ascent-connected-component5-candidate-v2/attachment-source-1.png'),decision='Personally viewed complete76-face source roof. Exact shared vertices connect it to the already reviewed building shell; apply the identical finite region, preserving every source height and alpha.')
    if version>=6:report['mountedAssemblyReview']=dict(objects=sorted(mounted),geometryReview=str(REV/'ascent-poster-source-review-v1/review.json'),materialReview=str(REV/'ascent-mounted-material-review-v1/review.json'),materialReviewSha256=sha(REV/'ascent-mounted-material-review-v1/review.json'),decision='Root reviewed all eight mounted sheets with both static door frames and wall6502. Map their complete retained profiles through the shared finite field; preserve alpha masks, Z and existing translucent glass omissions. Window/conduit remain outside this additional approval scope.')
    if version>=7:
        report['mountedAssemblyReview']['windowConduitReview']=str(REV/'ascent-window-conduit-source-review-v1')
        report['mountedAssemblyReview']['decision']='Root reviewed all eight mounted sheets, both static door frames, the full open window frame6571 and attached octagonal conduit769. Their actual retained surfaces share the adjoining wall field. Preserve all Z, window opening and masked texture holes, with no extrusion or added fill. Existing translucent glass omissions remain unchanged.'
    if version>=8:
        report['wallReliefReview']=dict(path=str(REV/'ascent-149-corner-relief-review-v1/review.json'),sha256=sha(REV/'ascent-149-corner-relief-review-v1/review.json'),decision='Both complete24-face source relief strips on the already reviewed MidWallA8034 share their incident169.5/171.5 wall normal-depth bands. Preserve original tangent/Z extents and source holes; add no geometry.')
    output=OUT/f'component5-region-declarations-v{version}.json'
    if output.exists():raise FileExistsError(output)
    output.write_text(json.dumps(report,indent=2)+'\n');print(json.dumps(topology,indent=2))


if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('--version',type=int,default=3);main(p.parse_args().version)

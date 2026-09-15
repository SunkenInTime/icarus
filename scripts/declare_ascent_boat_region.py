"""Shared finite source field for the boat and its connected wall assemblies."""
import argparse,json,gzip
from pathlib import Path
import numpy as np
import shapely
from prepare_ascent_connected_corners import ROOT,REV,OUT
from tactical_alignment_composite import explicit_warp
from authored_wall_profile_cells import partition_linear
from verify_region_mapping import verify_region_topology
from native_compact_wall_profiles import sha


def main(version):
    review=json.loads((OUT/'finite-component-declaration-review-v2.json').read_text());rows={r['completeSpan']:r for r in review['components'][1]['spans']};prior=json.loads((OUT/'boat-connected-frame-declarations-v1.json').read_text());rawpath=ROOT/'supplemented-v2/world/ascent/geometry.npz';raw=np.load(rawpath);aff=np.asarray(json.loads((ROOT/'tactical-alignment-sides-v1/ascent.json').read_text())['nativeToAttackSvg']);meta=json.loads(rawpath.with_suffix('.json').read_text());boat=np.load(OUT/'boat-208-profile-source.npz')['sourceTrianglesSvgZ'];low=boat[:,:,:2].min((0,1));high=boat[:,:,:2].max((0,1));bands=[{},{}]
    for span,axis,target in [(205,0,148.5),(206,1,158.),(207,0,138.),(209,1,172.),(210,0,128.5),(211,1,175.5)]:
        ids=rows[span]['families'][0]['sourceFaces'];xy=raw['points'][raw['faces'][ids]][:,:,:2]@aff[:,:2].T+aff[:,2];bands[axis][target]=[float(xy[:,:,axis].min()),float(xy[:,:,axis].max())]
    bands[0][133.5]=[float(low[0]),prior['sharedBoatJoins'][1]['sourceSvg'][0]];bands[0][138.][1]=max(bands[0][138.][1],float(high[0]));bands[1][167.5]=[float(low[1]),prior['sharedBoatJoins'][0]['sourceSvg'][1]];bands[1][172.][1]=max(bands[1][172.][1],float(high[1]))
    relief=None
    if version>=6:
        # CourtyardWall2B's low plinth projects slightly beyond its primary
        # front sheets. It is the same reviewed L-shaped wall assembly.
        obj=meta['objects'][7556];relief_ids=np.arange(obj['firstFace'],obj['firstFace']+obj['faceCount'])
        xy=raw['points'][raw['faces'][relief_ids]][:,:,:2]@aff[:,:2].T+aff[:,2]
        bands[0][138.][0]=min(bands[0][138.][0],float(xy[:,:,0].min()))
        bands[1][158.][0]=min(bands[1][158.][0],float(xy[:,:,1].min()))
        relief=dict(sourceObject=7556,sourcePath=obj['path'],originalSourceFaceIds=relief_ids.tolist(),frontNormalMinimaSvg=[float(xy[:,:,0].min()),float(xy[:,:,1].min())],evidence=str(REV/'ascent-connected-boat-candidate-v5/frozen-render-contact-sources.json'),evidenceSha256=sha(REV/'ascent-connected-boat-candidate-v5/frozen-render-contact-sources.json'),decision='Bind the complete already reviewed wall plinth to its authored138/158 front planes. Preserve source Z and all tangent extents; separate CanalPole7222 stays unchanged.')
    knots=[];mapped=[]
    for axis in [0,1]:
        pairs=[];last=-np.inf
        for target,extent in sorted(bands[axis].items()):
            assert extent[0]>last,(axis,target,extent,last)
            pairs.extend((v,target) for v in sorted(set(extent)));last=extent[1]
        x=np.asarray([v for v,t in pairs]);y=np.asarray([t for v,t in pairs]);x=np.r_[x[0]-4,x[0]-2,x,x[-1]+2,x[-1]+4];y=np.r_[x[:2],y,x[-2:]];knots.append(x);mapped.append(y)
    wpath=REV/'display-warps-v1/ascent.display-warp.json.gz';w=json.loads(gzip.decompress(wpath.read_bytes()));wp=np.asarray(w['sourceNativeMeters']).reshape(-1,2)@aff[:,:2].T+aff[:,2];wt=np.asarray(w['targetAttackSvg']).reshape(-1,2);wi=np.asarray(w['triangles']).reshape(-1,3);forward=explicit_warp(wp,wt-wp,wi);wpolys=shapely.polygons(wp[wi]);tree=shapely.STRtree(wpolys)
    xs,ys=knots;grid=np.asarray([[x,y] for y in ys for x in xs]);desired=np.asarray([[x,y] for y in mapped[1] for x in mapped[0]]);nx=len(xs);outer=(np.isin(grid[:,0],[xs[0],xs[-1]])|np.isin(grid[:,1],[ys[0],ys[-1]]));desired[outer]=forward.apply(grid[outer]);base=[]
    for j in range(len(ys)-1):
        for i in range(nx-1):q=j*nx+i;base.extend([[q,q+1,q+nx+1],[q,q+nx+1,q+nx]])
    if version>=5:
        # Inside the boat footprint every old axis-cell subdivision evaluates
        # the same scalar along-profile function. Remove those irrelevant
        # internal edges before partitioning at its two actual clamp planes.
        base=[ids for ids in base if not (np.all(grid[ids].mean(0)>low) and np.all(grid[ids].mean(0)<high))]
        corners=[np.flatnonzero(np.all(grid==p,axis=1))[0] for p in [low,[high[0],low[1]],high,[low[0],high[1]]]]
        base.extend([[int(corners[0]),int(corners[1]),int(corners[2])],[int(corners[0]),int(corners[2]),int(corners[3])]])
    tangent=np.asarray([-1.,1.])/np.sqrt(2);origin=np.asarray([138.,167.5]);alo,ahi=prior['boatSourceAlong'];target0=np.asarray([138.,167.5]);target1=np.asarray([133.5,172.]);source=[];target=[];cells=[];lookup={}
    for ids in base:
        a=grid[ids];b=desired[ids];parts=[a];inside=np.all(a.mean(0)>low)&np.all(a.mean(0)<high)
        if inside:parts=partition_linear(a,origin,tangent,[alo,ahi])
        shapes=[shapely.Polygon(p) for p in parts]
        # The independent boundary proof below checks every W crossing. Do not
        # extend irrelevant W cell edges into the interior of a source cell.
        for shape in shapes:
            if shape.geom_type!='Polygon' or shape.area<=1e-16:continue
            coords=np.asarray(shape.exterior.coords)[:-1];uv=np.linalg.solve((a[1:]-a[0]).T,(coords-a[0]).T).T;targets=b[0]+uv@(b[1:]-b[0]);in_boat=np.all(coords>=low-1e-9,axis=1)&np.all(coords<=high+1e-9,axis=1)
            u=np.clip(((coords[in_boat]-origin)@tangent-alo)/(ahi-alo),0,1);targets[in_boat]=target0+u[:,None]*(target1-target0)
            on_outer=(np.isclose(coords[:,0],xs[0],atol=1e-9,rtol=0)|np.isclose(coords[:,0],xs[-1],atol=1e-9,rtol=0)|np.isclose(coords[:,1],ys[0],atol=1e-9,rtol=0)|np.isclose(coords[:,1],ys[-1],atol=1e-9,rtol=0));targets[on_outer]=forward.apply(coords[on_outer]);indices=[]
            for p,q in zip(coords,targets):
                key=tuple(np.rint(p*1e9).astype(np.int64))
                if key in lookup:
                    index=lookup[key];assert np.linalg.norm(np.asarray(source[index])-p)<2e-9 and np.linalg.norm(np.asarray(target[index])-q)<2e-8
                else:index=len(source);lookup[key]=index;source.append(p.tolist());target.append(q.tolist())
                indices.append(index)
            cells.extend([[indices[0],indices[j],indices[j+1]] for j in range(1,len(indices)-1) if len({indices[0],indices[j],indices[j+1]})==3])
    # Node only the finite outer boundary at actual W events, assigning its
    # exact W value. The collar's interior absorbs the continuous transition.
    boundary_edges=set()
    for ids in base:
        for a,b in zip(ids,np.roll(ids,-1)):
            if outer[a] and outer[b] and (grid[a,0]==grid[b,0] or grid[a,1]==grid[b,1]):boundary_edges.add(tuple(sorted((int(a),int(b)))))
    for a,b in boundary_edges:
        line=shapely.LineString(grid[[a,b]])
        for index in tree.query(line):
            cut=line.intersection(wpolys[index])
            if cut.is_empty:continue
            assert cut.geom_type in ['LineString','Point']
            for p in np.asarray(cut.coords):
                key=tuple(np.rint(p*1e9).astype(np.int64));q=forward.apply(p[None])[0]
                if key in lookup:continue
                lookup[key]=len(source);source.append(p.tolist());target.append(q.tolist())
    sp=np.asarray(source);tp=np.asarray(target);noded=[]
    for ids in cells:
        boundary=[]
        for a,b in zip(ids,np.roll(ids,-1)):
            d=sp[b]-sp[a];length=np.linalg.norm(d);u=(sp-sp[a])@d/(length*length);distance=np.abs((sp[:,0]-sp[a,0])*d[1]-(sp[:,1]-sp[a,1])*d[0])/length;interior=np.flatnonzero((u>1e-12)&(u<1-1e-12)&(distance<1e-10));boundary.append(int(a));boundary.extend(interior[np.argsort(u[interior])].tolist())
        if len(boundary)==3:noded.append(ids);continue
        center=len(source);source.append(sp[ids].mean(0).tolist());target.append(tp[ids].mean(0).tolist());noded.extend([[center,a,b] for a,b in zip(boundary,boundary[1:]+boundary[:1])])
    objects=[7555,7556,6872,7206,6959]+([7586] if version>=3 else []);ids=[j for i in objects for j in range(meta['objects'][i]['firstFace'],meta['objects'][i]['firstFace']+meta['objects'][i]['faceCount'])]
    family=dict(edge=207208209,mappingType='piecewise-affine-region-v1',completeSpans=list(range(205,212)),sourceVerticesSvg=source,targetVerticesSvg=target,triangles=noded,objects=objects,sourceObjects=[dict(sourceObjectIndex=i,path=meta['objects'][i]['path']) for i in objects],reviewedSourceFaceIds=ids,box=[xs[0],ys[0],xs[-1],ys[-1]],identityOuterBoundary=True,boatSourceBoundsSvg=[low.tolist(),high.tolist()],boatSourceAlong=[alo,ahi],reviewedAuthoredSpans=[dict(completeSpan=i,startSvg=rows[i]['authoredEndpoints'][0],endSvg=rows[i]['authoredEndpoints'][1]) for i in range(205,212)],role='Complete reviewed boat, adjoining courtyard walls, arch and backing share one finite field. Exact original heights and alpha retained. Separate non-contact endpoint poles retain their source identities outside this family.')
    output=OUT/f'boat-region-declarations-v{version}.json'
    try:topology=verify_region_topology(family,forward)
    except AssertionError:
        (OUT/'boat-region-rejected-v2.json').write_text(json.dumps(family,indent=2)+'\n');raise
    report=dict(map='ascent',format='icarus-connected-boat-region-declarations-v1',component=7,families=[family],sourceFileSha256=sha(rawpath),scriptSha256=sha(Path(__file__)),sourceNeighborPreflight=str(OUT/f'boat-region-source-neighbors-v{version}.json'),sourceEndpointControl=str(OUT/'boat-connected-frame-declarations-v1.json'),topology=topology,productionMutation=False,acceptance=False,scope='Finite complete boat attachment field; source profile and closure verification required before rendering. Wider component7 remains unfinished.')
    if relief:report['wallPlinthReview']=relief
    assert not output.exists();output.write_text(json.dumps(report,indent=2)+'\n');print(json.dumps(topology,indent=2))

if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('--version',type=int,default=3);main(p.parse_args().version)

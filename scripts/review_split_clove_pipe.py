"""Original pipe/backing geometry and exact frozen Clove notch first hits.

Read-only packet. Relative-floor renderer rays and absolute standing-height
source rays are reported separately; neither silently substitutes for the other.
"""
import bisect
import gzip
import json
from pathlib import Path

import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
from matplotlib.collections import LineCollection
from mpl_toolkits.mplot3d.art3d import Poly3DCollection
import numpy as np

from build_global_tactical_candidate import GroundField
from native_reference_cast import NativeReferenceModel
from native_compact_wall_profiles import sha
from tactical_alignment_composite import explicit_warp
from render_competing_floor_assemblies import clip_mesh_xy
from render_split_remaining_corner_families import sections
from probe_split_component7_continuation import point_heights

ROOT = Path('E:/IcarusWorldAudit/2026-09-06')
REV = ROOT/'tactical-visibility-revision'


def closest_point(triangles, points):
    a,b,c=np.moveaxis(triangles,1,0)
    normal=np.cross(b-a,c-a);norm2=(normal*normal).sum(1)
    projection=points-normal*((points-a)*normal).sum(1)[:,None]/np.maximum(norm2[:,None],1e-300)
    u=b-a;v=c-a;w=projection-a
    uu=(u*u).sum(1);uv=(u*v).sum(1);vv=(v*v).sum(1);wu=(w*u).sum(1);wv=(w*v).sum(1)
    det=uu*vv-uv*uv
    valid=abs(det)>1e-25;den=np.where(valid,det,1)
    x=(wu*vv-wv*uv)/den;y=(wv*uu-wu*uv)/den
    inside=valid&(x>=0)&(y>=0)&(x+y<=1)
    choices=[]
    for start,end in [(a,b),(b,c),(c,a)]:
        edge=end-start;length2=(edge*edge).sum(1)
        t=np.clip(((points-start)*edge).sum(1)/np.maximum(length2,1e-300),0,1)
        choices.append(start+t[:,None]*edge)
    choices.append(projection)
    candidates=np.stack(choices,axis=1);distances=((candidates-points[:,None])**2).sum(2)
    distances[~inside,3]=np.inf
    return candidates[np.arange(len(triangles)),distances.argmin(1)]


def main():
    output = REV/'split-clove-pipe7479-review-v3'
    output.mkdir(exist_ok=False)
    candidate = REV/'split-wall-family-normalized-candidate-v26'
    manifest_path = REV/'frozen-split-app-scene-v26-run1/manifest.json'
    manifest = json.loads(manifest_path.read_text())
    query = np.asarray(manifest['records'][0]['sourceQueries'][4])
    raw_path = ROOT/'supplemented-v2/world/split/geometry.npz'
    raw = np.load(raw_path)
    points, faces = raw['points'], raw['faces']
    meta = json.loads(raw_path.with_suffix('.json').read_text())
    starts = [o['firstFace'] for o in meta['objects']]
    warp_path = REV/'display-warps-v1/split.display-warp.json.gz'
    warp = json.loads(gzip.decompress(warp_path.read_bytes()))
    matrix = np.column_stack((warp['projection']['axisU'],warp['projection']['axisV']))
    origin = np.asarray(warp['projection']['origin'])
    w_source = np.asarray(warp['sourceNativeMeters']).reshape(-1,2)
    w_target = np.asarray(warp['targetAttackSvg']).reshape(-1,2)
    cells = np.asarray(warp['triangles']).reshape(-1,3)
    forward = explicit_warp(w_source,w_target-w_source,cells)
    inverse = explicit_warp(w_target,w_source-w_target,cells)
    control_path = REV/'global-ground-complete-v2/split/split.height.bin.gz'
    full_path = REV/'full-height-input-v1/split/split.height.bin.gz'
    library = REV/'native-tactical-rays-build/Release/tactical_reference_cast.dll'
    caster = NativeReferenceModel(candidate/'split.height.bin.gz',library)
    full = NativeReferenceModel(full_path,library)
    ground = GroundField(control_path.parent/'split.tactical-ground.json.gz')
    original_eye = float(query[2]+ground.heights(query[None,:2])[0])
    chains = [np.load(path)['sourceFaces'] for path in [candidate/'correspondence.npz',
        control_path.parent/'correspondence.npz',full_path.parent/'source-correspondence.npz']]
    proposal = json.loads(gzip.decompress((REV/'split-connected-contour-proposals-v2/component-4.json.gz').read_bytes()))
    spans = [s for s in proposal['spans'] if s['completeSpan'] in [129,130,131]]
    source_objects = [7478,7479,7480,7481,7633,7634,3963,7609,7612,7797,7790]
    mesh = {}
    object_rows = []
    for obj in source_objects:
        record = meta['objects'][obj]
        ids = np.arange(record['firstFace'],record['firstFace']+record['faceCount'])
        xyz = points[faces[ids]].astype(float)
        mesh[obj] = (ids,xyz)
        object_rows.append(dict(object=obj,**record,sourceZ=[float(xyz[:,:,2].min()),float(xyz[:,:,2].max())],
            materials=[dict(id=int(i),**meta['materials'][int(i)]) for i in np.unique(raw['material_indices'][ids])]))
    pipe_ids=np.concatenate([mesh[obj][0] for obj in [7478,7479,7480,7481]])
    pipe=np.concatenate([mesh[obj][1] for obj in [7478,7479,7480,7481]])
    # Exact closest point on nearby raw triangles for every pipe vertex and
    # centroid. These samples describe physical attachment; they are not a
    # complete minimum-distance proof between two arbitrary triangle meshes.
    samples = np.unique(np.r_[pipe.reshape(-1,3),pipe.mean(1)],axis=0)
    bounds = np.asarray([o['boundsMeters'] for o in meta['objects']])
    lo,hi = pipe.min((0,1)),pipe.max((0,1))
    nearby = np.flatnonzero((bounds[:,1]>=lo-.6).all(1)&(bounds[:,0]<=hi+.6).all(1))
    contact_rows = []
    for obj in nearby:
        if obj in [7478,7479,7480,7481]:
            continue
        o = meta['objects'][obj]
        ids = np.arange(o['firstFace'],o['firstFace']+o['faceCount'])
        tri = points[faces[ids]].astype(float)
        local = (tri.max(1)>=lo-.6).all(1)&(tri.min(1)<=hi+.6).all(1)
        ids,tri = ids[local],tri[local]
        if not len(tri):
            continue
        distances=[];records=[]
        for p in samples:
            nearest=closest_point(tri,np.repeat(p[None],len(tri),axis=0))
            d=np.linalg.norm(nearest-p,axis=1);k=int(d.argmin())
            distances.append(float(d[k]));records.append((k,nearest[k]))
        k=int(np.argmin(distances));face,nearest=records[k]
        contact_rows.append(dict(object=int(obj),path=o['path'],sampleMinimumDistanceMeters=distances[k],
            samplePoint=samples[k].tolist(),nearestPoint=nearest.tolist(),originalFace=int(ids[face]),
            samplesWithin1mm=int(np.sum(np.array(distances)<.001)),samplesWithin1cm=int(np.sum(np.array(distances)<.01))))
    contact_rows.sort(key=lambda r:r['sampleMinimumDistanceMeters'])
    trace=[]
    direction_angle=np.arctan2(query[4],query[3])
    for span in spans:
        a,b=np.asarray(span['authoredEndpoints']);length=np.linalg.norm(b-a)
        for along in np.linspace(0,length,max(3,int(length/.01)+1)):
            target=a+(b-a)*along/length;goal=inverse.apply(target[None])[0]
            delta=goal-query[:2];distance=np.linalg.norm(delta)
            angle=np.arctan2(delta[1],delta[0]);difference=np.arctan2(np.sin(angle-direction_angle),np.cos(angle-direction_angle))
            if abs(difference)>query[6]/2 or distance>query[5]:
                continue
            end=query[:2]+delta*(1+1/distance)
            hit=caster.cast(query[:3],np.r_[end,query[2]])
            source_hit=full.cast(np.r_[query[:2],original_eye],np.r_[end,original_eye])
            row=dict(span=span['completeSpan'],alongSvg=float(along),targetSvg=target.tolist(),targetNative=end.tolist())
            if hit:
                ids=[hit['face']]
                for chain in chains:ids.append(int(chain[ids[-1]]))
                obj=bisect.bisect_right(starts,ids[-1])-1
                row.update(candidateHit=hit,faceChain=ids,sourceObject=obj,sourcePath=meta['objects'][obj]['path'],
                    hitSvg=forward.apply(np.asarray(hit['point'][:2])[None])[0].tolist())
                if obj in [7478,7479,7480,7481]:
                    row['unchangedPipeOriginalHitZ']=float(hit['point'][2]+ground.heights(np.asarray(hit['point'][:2])[None])[0])
            if source_hit:
                source_id=int(chains[-1][source_hit['face']]);obj=bisect.bisect_right(starts,source_id)-1
                row.update(absoluteSourceHit=source_hit,absoluteSourceFace=source_id,absoluteSourceObject=obj)
            trace.append(row)
    # Independent navigation layer samples at the exact observer XY.
    nav_path=REV/'baseline-world/split_navigation.json.gz'
    nav=json.loads(gzip.decompress(nav_path.read_bytes()))
    catalog=json.loads((REV/'baseline-world/height_catalog.json').read_text())['maps']['split']['uiTransform']
    detail=nav['floorMesh'];vertices=np.asarray(detail['vertices'],float).reshape(-1,3)
    uv=vertices[:,:2]/detail['coordinateScale']
    vertices[:,0]=(uv[:,1]-catalog['YScalarToAdd'])/(100*catalog['YMultiplier'])
    vertices[:,1]=-(uv[:,0]-catalog['XScalarToAdd'])/(100*catalog['XMultiplier']);vertices[:,2]/=100
    dt=np.asarray(detail['triangles']).reshape(-1,4);dt=dt[np.asarray(nav['walkable'])[dt[:,0]]]
    ni,nz=point_heights(vertices[dt[:,1:]],query[:2])
    # Original 3D context and source-height sections, never the flattened Z.
    fig=plt.figure(figsize=(17,10));colors={7478:'#c2410c',7479:'#ea580c',7480:'#f97316',7481:'#fb923c',7633:'#b91c1c',7634:'#b91c1c',3963:'#a16207',7609:'#2563eb',7612:'#059669',7797:'#9333ea',7790:'#64748b'}
    box=np.array([230.,209.,244.,221.]);svg_mesh={}
    for obj,(_,xyz) in mesh.items():
        tri=xyz.copy();tri[:,:,:2]=tri[:,:,:2]@matrix.T+origin
        svg_mesh[obj]=clip_mesh_xy(tri,box[:2],box[2:])
    for k,azimuth in enumerate([-60,125]):
        ax=fig.add_subplot(2,3,1+k*3,projection='3d')
        for obj,tri in svg_mesh.items():
            ax.add_collection3d(Poly3DCollection(tri,facecolor=colors[obj],edgecolor=colors[obj],alpha=.65 if obj in [7478,7479,7480,7481] else .15,linewidths=.25))
        ax.set_xlim(box[0],box[2]);ax.set_ylim(box[1],box[3]);ax.set_zlim(5,13)
        ax.view_init(25,azimuth);ax.set_box_aspect([14,12,8*3.91]);ax.set_zlabel('Original source Z, m')
        ax.set_title('Orange pipe7478–7481, red ports7633/7634, blue wall7609')
    for slot,z in zip([2,3,5,6],[original_eye,8.,8.25,9.25]):
        ax=fig.add_subplot(2,3,slot)
        for obj,tri in svg_mesh.items():
            lines,_=sections(tri,z)
            if len(lines):ax.add_collection(LineCollection(lines,colors=colors[obj],linewidths=1.2,label=str(obj)))
        for span in spans:
            line=np.asarray(span['authoredEndpoints']);ax.plot(*line.T,color='black',lw=2);ax.text(*line.mean(0),str(span['completeSpan']))
        ax.set_xlim(box[0],box[2]);ax.set_ylim(box[3],box[1]);ax.set_aspect('equal');ax.grid(alpha=.2)
        ax.set_title(f'Original source Z {z:.6f} m');ax.legend(fontsize=7)
    fig.suptitle('Clove notch129–131: complete pipe and connected source-wall context\nBlack is authored contour. Source sections retain actual Z; no role change or mapping is applied.')
    fig.tight_layout();fig.savefig(output/'source-height-context.png',dpi=170);plt.close(fig)
    fig,ax=plt.subplots(figsize=(9,9))
    for span in spans:
        line=np.asarray(span['authoredEndpoints']);ax.plot(*line.T,color='black',lw=2);ax.text(*line.mean(0),str(span['completeSpan']))
    for obj in sorted({row.get('sourceObject',-1) for row in trace}):
        hits=np.array([row['hitSvg'] for row in trace if row.get('sourceObject')==obj])
        if len(hits):ax.scatter(*hits.T,s=5,c=colors.get(obj,'gray'),label=f'V26 first hit {obj}')
    mesh_path=Path(manifest['records'][0]['sourceMeshFiles'][4])
    vertices=np.fromfile(mesh_path,dtype=np.float32).reshape(-1,2).astype(float)+query[:2]
    displayed_vertices=forward.apply(vertices)
    inside=(displayed_vertices>=box[:2]).all(1)&(displayed_vertices<=box[2:]).all(1)
    ax.scatter(*displayed_vertices[inside].T,s=16,facecolors='none',edgecolors='#db2777',linewidths=.6,label='Actual app shadow vertices')
    ax.set_xlim(box[0],box[2]);ax.set_ylim(box[3],box[1]);ax.set_aspect('equal');ax.grid(alpha=.2);ax.legend()
    ax.set_title('Frozen Clove silhouette: source-attributed first hits and actual app mesh\nAuthored target intervals sampled every0.01SVG. Pink mesh uses storedfloat32 coordinates.')
    fig.tight_layout();fig.savefig(output/'frozen-silhouette-source-contacts.png',dpi=180);plt.close(fig)
    np.savez_compressed(output/'source-context.npz',sourceFaceIds=np.concatenate([a for a,b in mesh.values()]),
        sourceObjectIds=np.concatenate([np.full(len(a),obj) for obj,(a,b) in mesh.items()]),triangles=np.concatenate([b for a,b in mesh.values()]))
    report=dict(scope=__doc__,sourceGeometrySha256=sha(raw_path),manifestSha256=sha(manifest_path),
        candidatePackSha256=sha(candidate/'split.height.bin.gz'),warpSha256=sha(warp_path),
        fullSourcePackSha256=sha(full_path),navSha256=sha(nav_path),scriptSha256=sha(Path(__file__)),
        actualQuery=query.tolist(),originalObserverEyeMeters=original_eye,
        detailedNavParentIds=dt[ni,0].tolist(),detailedNavFloorHeightsMeters=nz.tolist(),
        pipeMinimumAboveObserverEyeMeters=float(pipe[:,:,2].min()-original_eye),
        objects=object_rows,nearbySourceContactSamples=contact_rows,
        authoredSpans=[dict(span=s['completeSpan'],ends=s['authoredEndpoints']) for s in spans],rays=trace,
        candidateFirstHitCounts={str(o):sum(r.get('sourceObject',-1)==o for r in trace) for o in sorted({r.get('sourceObject',-1) for r in trace})},
        absoluteFirstHitCounts={str(o):sum(r.get('absoluteSourceObject',-1)==o for r in trace) for o in sorted({r.get('absoluteSourceObject',-1) for r in trace})},
        actualAppShadowMeshSha256=sha(mesh_path),
        limitations=['Closest-point samples are attachment evidence, not a complete triangle-contact proof.',
                     'Absolute horizontal source comparison does not implement tactical ramp flattening.',
                     'No source roles, materials, geometry, app files or packs changed.'])
    (output/'review.json').write_text(json.dumps(report,indent=2)+'\n')
    pipe_rows=[row for row in trace if row.get('sourceObject')==7479]
    span130=next(s for s in spans if s['completeSpan']==130)
    a,b=np.asarray(span130['authoredEndpoints']);tangent=(b-a)/np.linalg.norm(b-a);normal=np.array([-tangent[1],tangent[0]])
    recommendation=dict(status='Read-only source-backed recommendation; no role or geometry change',
        authoredSpan=130, authoredEnds=span130['authoredEndpoints'],
        proposedPipeObjects=[7478,7479,7480,7481],proposedConnectedPorts=[7633,7634],
        proposedPipeAndPortSourceFaces=np.concatenate([mesh[obj][0] for obj in [7478,7479,7480,7481,7633,7634]]).tolist(),
        reviewedBacking=7609,nearbySeparateFloater=3963,
        sourceHeightPolicy='Keep each actual source triangle Z, UV, material and finite height extent. No extrusion or foliage filtering.',
        physicalInterpretation='Four connected pipe pieces form one vertical service pipe. Its upper elbow meets a wall port; its bottom meets a ground port. The authored diagonal130 cuts through the circular frontage. Shared mapping should align this connected profile with130 and preserve its joins to adjacent mapped wall regions.',
        mappingCaution='Existing region mapping was designed for the square backing. Merely adding pipe source IDs to that field need not flatten the circular frontage. Declare a source-backed local profile band for130 and continuous end/port transitions before baking.',
        frozenPipeHitCount=len(pipe_rows),maximumFrozenPipeOffsetSvg=max(abs((np.asarray(row['hitSvg'])-a)@normal) for row in pipe_rows),
        frozenRelativeEyeMeters=float(query[2]),originalStandingEyeMeters=original_eye,
        frozenPipeHitOriginalZRange=[min(row['unchangedPipeOriginalHitZ'] for row in pipe_rows),max(row['unchangedPipeOriginalHitZ'] for row in pipe_rows)],
        originalHorizontalComparison='Original eye hits lower segment7478 rather than7479. Restoring absolute eye height alone does not remove the pipe silhouette. Tactical floor semantics remain separate.',
        reportSha256=sha(output/'review.json'),sourcePacketSha256=sha(output/'source-context.npz'))
    (output/'recommendation.json').write_text(json.dumps(recommendation,indent=2)+'\n')
    print(json.dumps({k:report[k] for k in ['actualQuery','originalObserverEyeMeters','detailedNavFloorHeightsMeters','pipeMinimumAboveObserverEyeMeters','candidateFirstHitCounts','absoluteFirstHitCounts','nearbySourceContactSamples']},indent=2))


if __name__=='__main__':main()

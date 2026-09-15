"""Connected generator/cover source-profile proposal, retaining authored cubic 204.

This writes an isolated review declaration and source-height previews. It does
not alter a source pack or authorize a cumulative candidate bake.
"""
import argparse
import gzip
import json
from pathlib import Path

import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
from matplotlib.collections import LineCollection
import numpy as np
import shapely

from authored_cubic_segments import cubic_segments
from native_compact_wall_profiles import sha
from tactical_alignment_composite import explicit_warp
from verify_region_mapping import verify_region_topology
from render_split_remaining_corner_families import sections

ROOT=Path('E:/IcarusWorldAudit/2026-09-06')
REV=ROOT/'tactical-visibility-revision'
CONTROLS=np.array([[40.3722,186.527],[40.3722,186.952],[65.1816,186.704],[77.5863,186.527]])


def bezier(t):
    t=np.asarray(t)
    return ((1-t)[...,None]**3*CONTROLS[0]+3*((1-t)**2*t)[...,None]*CONTROLS[1]
            +3*((1-t)*t*t)[...,None]*CONTROLS[2]+(t**3)[...,None]*CONTROLS[3])


def curve_y(x):
    if x<=CONTROLS[0,0] or x>=CONTROLS[-1,0]:
        return 186.527
    low,high=0.,1.
    for _ in range(60):
        t=(low+high)/2
        if bezier(t)[0]<x: low=t
        else: high=t
    return float(bezier((low+high)/2)[1])


def inverse_columns(columns,anchors):
    """Each repeated target coordinate has distinct near/far source bounds."""
    keys=sorted(anchors)
    result=[]
    for x,side in columns:
        if x in anchors:
            result.append(anchors[x][side])
        else:
            j=int(np.searchsorted(keys,x));a,b=keys[j-1:j+1]
            result.append(anchors[a][1]+(x-a)/(b-a)*(anchors[b][0]-anchors[a][1]))
    return np.array(result)


def main(version):
    output=REV/f'split-generator-connected-profile-proposal-{version}'
    output.mkdir(exist_ok=False)
    packet_path=REV/'split-component8-source-review-v3/full-source-context.npz'
    packet=np.load(packet_path)
    source_tri=packet['sourceTrianglesSvgZ'];owners=packet['sourceObjectIds']
    correspondence_path=REV/'full-height-input-v1/split/source-correspondence.npz'
    retained=np.isin(packet['sourceFaceIds'],np.load(correspondence_path)['sourceFaces'])
    raw_path=ROOT/'supplemented-v2/world/split/geometry.npz'
    raw=np.load(raw_path);metadata=json.loads(raw_path.with_suffix('.json').read_text())
    material_ids=raw['material_indices'][packet['sourceFaceIds']]
    materials=[dict(material=int(mid),rawFaces=int((material_ids==mid).sum()),
        retainedFaces=int(((material_ids==mid)&retained).sum()),
        omittedOriginalFaces=packet['sourceFaceIds'][(material_ids==mid)&~retained].tolist(),
        originalMaterial=metadata['materials'][mid]) for mid in np.unique(material_ids)]
    warp_path=REV/'display-warps-v1/split.display-warp.json.gz'
    w=json.loads(gzip.decompress(warp_path.read_bytes()))
    matrix=np.column_stack([w['projection']['axisU'],w['projection']['axisV']]);origin=np.asarray(w['projection']['origin'])
    ws=np.asarray(w['sourceNativeMeters']).reshape(-1,2)@matrix.T+origin
    wt=np.asarray(w['targetAttackSvg']).reshape(-1,2)
    forward=explicit_warp(ws,wt-ws,np.asarray(w['triangles']).reshape(-1,3))
    constraints=[]
    def exact(obj,axis,approx):
        values=source_tri[owners==obj,:,axis].reshape(-1)
        value=float(values[np.argmin(abs(values-approx))])
        assert abs(value-approx)<2e-5,(obj,axis,approx,value)
        ids=packet['sourceFaceIds'][(owners==obj)&np.any(source_tri[:,:,axis]==value,axis=1)]
        constraints.append(dict(sourceObject=obj,axis=axis,reviewApproximation=approx,
                                sourceCoordinate=value,sourceFaceIds=ids.tolist()))
        return value
    # The source bounds come from the complete reviewed assemblies, not a
    # single first-hit face. No source height is generated from these bounds.
    gen_left=[exact(6577,0,40.06979928),exact(6577,0,40.33013)]
    gen_right=[77.8,exact(6577,0,77.93181860)]
    box_left=[exact(6694,0,56.48159458),exact(6694,0,56.78146)]
    box_right=[exact(6694,0,64.00097),exact(6694,0,64.30083513)]
    stack_left=[exact(6693,0,70.12240266),exact(6692,0,70.27376)]
    stack_right=[exact(6693,0,77.45862665),exact(6693,0,77.94164321)]
    source_front_low=exact(6577,1,186.11316)
    source_front_high=exact(6577,1,187.02293)
    rows=[153.,157.,exact(6694,1,161.59722577),exact(6694,1,161.89709),
          exact(6577,1,169.13159367),exact(6577,1,169.47408),source_front_low,
          source_front_high,187.2,exact(6693,1,194.33386764),exact(6693,1,194.79846912),199.,203.]
    ys=[153.,157.,161.54,161.54,168.983,168.983,None,None,None,194.501,194.501,199.,203.]
    cubic=cubic_segments(CONTROLS,1e-5)
    anchors={30.:[30.,30.],35.:[35.,35.],40.3722:gen_left,56.3212:box_left,
             63.764:box_right,69.6119:stack_left,77.5863:gen_right,
             77.5864:[stack_right[1],78.],82.:[82.,82.],88.:[88.,88.]}
    lower=dict(anchors)
    lower[77.5863]=[77.35,77.4]
    lower[77.5864]=stack_right
    curve_points=np.array([cubic[0]['startSvg']]+[r['endSvg'] for r in cubic])
    xs=set(curve_points[:,0])|set(anchors)
    # Every outer boundary crossing of the existing W is an explicit vertex.
    # This preserves the complete piecewise affine outer presentation boundary.
    boundary=shapely.box(30,153,88,203).boundary
    intersections=shapely.intersection(boundary,forward.tri.polygons[forward.tri.tree.query(boundary)])
    boundary_coords=shapely.get_coordinates(intersections)
    extra_rows=[]
    for x,y in boundary_coords:
        if y==153 or y==203: xs.add(float(x))
        if x==30 or x==88:
            if y not in rows:extra_rows.append(float(y))
    oldrows=np.array(rows)
    for y in sorted(set(extra_rows)):
        j=int(np.searchsorted(rows,y));rows.insert(j,y)
        # These outer-boundary noding rows interpolate the original row map.
        ys.insert(j,'interpolate')
    columns=[]
    for x in sorted(xs):
        columns.append((x,0))
        if x in anchors and anchors[x][1]!=anchors[x][0]:columns.append((x,1))
    xgen=inverse_columns(columns,anchors);xstack=inverse_columns(columns,lower)
    parameters=np.array([x for x,_ in columns])
    base_source=[];base_target=[]
    original_ys=[153.,157.,161.54,161.54,168.983,168.983,None,None,None,194.501,194.501,199.,203.]
    for i,y in enumerate(oldrows):
        blend=float(np.clip((y-source_front_high)/(187.2-source_front_high),0,1))
        x=(1-blend)*xgen+blend*xstack
        if y in [153.,203.]:x=parameters.copy()
        elif y in [157.,199.]:x=parameters.copy()
        target_y=np.full(len(x),original_ys[i]) if original_ys[i] is not None else np.array([curve_y(v) for v in parameters])
        source=np.column_stack((x,np.full(len(x),y)))
        target=np.column_stack((parameters,target_y)).astype(float)
        # Collapse repeated columns only inside the active bands. At the
        # outer rows their distinct source positions are retained below.
        base_source.append(source);base_target.append(target)
    # Repeated column parameters need positive-width outer source cells.
    # Use the generator source X on outer rows, then set their target to W.
    for i in [0,len(oldrows)-1]:
        base_source[i][:,0]=xgen
        base_target[i]=forward.apply(base_source[i])
    for i in [1,len(oldrows)-2]:
        base_source[i][:,0]=xgen
        base_target[i][:,0]=xgen
    source_rows=[];target_rows=[]
    for y in rows:
        if y in oldrows:
            j=int(np.flatnonzero(oldrows==y)[0]);s=base_source[j].copy();t=base_target[j].copy()
        else:
            j=int(np.searchsorted(oldrows,y));a=(y-oldrows[j-1])/(oldrows[j]-oldrows[j-1])
            s=base_source[j-1]+a*(base_source[j]-base_source[j-1]);t=base_target[j-1]+a*(base_target[j]-base_target[j-1])
            s[:,1]=y
        t[[0,-1]]=forward.apply(s[[0,-1]])
        source_rows.append(s);target_rows.append(t)
    source=np.concatenate(source_rows);target=np.concatenate(target_rows);count=len(columns)
    cells=[]
    for j in range(len(rows)-1):
        for i in range(count-1):
            a=j*count+i;b=a+1;c=a+count;d=c+1
            cells.extend([[a,b,d],[a,d,c]])
    cells=np.asarray(cells)
    family=dict(edge=200208,mappingType='region',box=[30.,153.,88.,203.],objects=[6577,6694,6692,6693],
        reviewedSourceFaces=packet['sourceFaceIds'].tolist(),sourceVerticesSvg=source.tolist(),
        targetVerticesSvg=target.tolist(),triangles=cells.tolist(),declaredRankOneMappings=[])
    # Each collapsed triangle has an independently recoverable affine scalar
    # along its actual authored line segment. Cubic pieces remain separate.
    for ci,cell in enumerate(cells):
        dst=target[cell];src=source[cell]
        dist=np.linalg.norm(dst[:,None]-dst[None,:],axis=2);ia,ib=np.unravel_index(dist.argmax(),dist.shape)
        if dist[ia,ib]==0:continue
        a,b=dst[[ia,ib]];delta=b-a;t=(dst-a)@delta/(delta@delta)
        expected=a+t[:,None]*delta
        if np.max(abs(dst-expected))>4*np.spacing(max(1.,abs(dst).max())):continue
        da,db=dst[1]-dst[0],dst[2]-dst[0]
        if abs(da[0]*db[1]-da[1]*db[0])>1e-9:continue
        gradient=np.linalg.solve(src[1:]-src[:1],t[1:]-t[0]);norm=np.linalg.norm(gradient)
        if norm==0:continue
        tangent=gradient/norm;origin_src=src[ia];length=1/norm
        t=np.clip(t,0,1)
        family['declaredRankOneMappings'].append(dict(id=f'generator-cell-{ci}',
            targetEndpointsSvg=[a.tolist(),b.tolist()],targetEndpointVertexIds=[int(cell[ia]),int(cell[ib])],
            sourceOriginSvg=origin_src.tolist(),sourceTangent=tangent.tolist(),sourceLengthSvg=float(length),
            sourceEndpointArithmeticSvg=1e-12,cells=[dict(cell=ci,vertexParameters=t.tolist())]))
    family['generatorReview']=dict(status='Source proposal only; no cumulative bake.',sourcePacketSha256=sha(packet_path),
        displayWarpSha256=sha(warp_path),sourceConstraints=constraints,cubic204=dict(controls=CONTROLS.tolist(),
        segments=cubic,maxControlHullDistanceBoundSvg=max(r['controlHullDistanceBoundSvg'] for r in cubic)),
        preservedDistinctRightEdges=[77.5863,77.5864],sourceZPolicy='Retain every original source Z and current UV/material admission.',
        materialAdmission=materials,fullSourceCorrespondenceSha256=sha(correspondence_path),
        unresolved=['Exact family contact gates precede any bake.',
                    'The lower cover rear is buried in the generator front band; verify both receiver footprints.',
                    'Source-neighbor preflight and current material admission are independent pending gates.'])
    path=output/'region-declaration.json';path.write_text(json.dumps(family,indent=2)+'\n')
    try:topology=verify_region_topology(family,forward)
    except (AssertionError,ValueError,np.linalg.LinAlgError) as error:topology=dict(passed=False,error=str(error))
    report=dict(declarationSha256=sha(path),sourceCells=len(cells),sourceVertices=len(source),topology=topology,
                productionMutation=False,scriptSha256=sha(Path(__file__)))
    (output/'proposal-review.json').write_text(json.dumps(report,indent=2)+'\n')
    print(json.dumps({k:v for k,v in report.items() if k!='topology'}|{'topology':
        {k:v for k,v in topology.items() if k!='declaredRankOneStoredResiduals'}}),flush=True)
    mapping=explicit_warp(source,target-source,cells)
    colors={6577:'#64748b',6694:'#ea580c',6692:'#16a34a',6693:'#9333ea'}
    fig,axes=plt.subplots(4,2,figsize=(14,18))
    targets=[np.array([[77.5863,168.983],[40.3722,168.983],[40.3722,186.527]]),curve_points,
             np.array([[77.5863,186.527],[77.5863,168.983]]),
             np.array([[56.3212,168.983],[56.3212,161.54],[63.764,161.54],[63.764,168.983]]),
             np.array([[69.6119,186.527],[69.6119,194.501],[77.5864,194.501],[77.5864,186.527]])]
    for row,z in enumerate([4.75,6.25,8.75,11.75]):
        for owner,color in colors.items():
            lines,_=sections(source_tri[(owners==owner)&retained],z)
            axes[row,0].add_collection(LineCollection(lines,colors=color,lw=.8))
            if len(lines):
                pts=lines[:,:1]+np.linspace(0,1,121)[None,:,None]*(lines[:,1:]-lines[:,:1])
                mapped=mapping.apply(pts.reshape(-1,2)).reshape(pts.shape)
                axes[row,1].add_collection(LineCollection(mapped,colors=color,lw=.8))
        for col in range(2):
            for line in targets:axes[row,col].plot(*line.T,color='black',lw=1)
            axes[row,col].set(xlim=(38,80),ylim=(197,159),title=f'{"Original" if col==0 else "Proposed"} source profiles at Z={z}m')
            axes[row,col].set_aspect('equal');axes[row,col].grid(alpha=.15)
    fig.suptitle('Generator and complete attached covers. Original heights retained; cubic204 preserved. Proposal only.')
    fig.tight_layout(rect=[0,0,1,.975]);fig.savefig(output/'source-height-profile-preview.png',dpi=150);plt.close(fig)


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--version',default='v1')
    main(parser.parse_args().version)

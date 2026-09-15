"""Finite connected130 pipe/profile mapping proposal, without a pack bake."""
from copy import deepcopy
from fractions import Fraction
import gzip
import json
from pathlib import Path

import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
from matplotlib.collections import LineCollection
import numpy as np

from native_compact_wall_profiles import sha
from tactical_alignment_composite import explicit_warp
from verify_region_mapping import verify_region_topology, verify_rank_one_declarations
from render_split_remaining_corner_families import sections

REV=Path('E:/IcarusWorldAudit/2026-09-06/tactical-visibility-revision')


def split_polygon(poly,axis,value):
    value=Fraction(float(value))
    distances=[p[axis]-value for p in poly]
    if min(distances)>=0 or max(distances)<=0:
        return [poly]
    left=[];right=[]
    for i,(p,q) in enumerate(zip(poly,poly[1:]+poly[:1])):
        a=distances[i];b=distances[(i+1)%len(poly)]
        (right if a>=0 else left).append(p)
        if (a>=0)!=(b>=0):
            t=a/(a-b);point=tuple(p[k]+t*(q[k]-p[k]) for k in range(2))
            left.append(point);right.append(point)
    return [p for p in [left,right] if len(p)>=3]


def declare():
    bindings_path=REV/'split-wall-family-normalized-candidate-v26/bindings.json'
    old=next(f for f in json.loads(bindings_path.read_text())['families'] if f['edge']==200190)
    packet_path=REV/'split-clove-pipe7479-review-v3/source-context.npz'
    packet=np.load(packet_path)
    warp_path=REV/'display-warps-v1/split.display-warp.json.gz'
    warp=json.loads(gzip.decompress(warp_path.read_bytes()))
    matrix=np.column_stack([warp['projection']['axisU'],warp['projection']['axisV']]);origin=np.asarray(warp['projection']['origin'])
    selected=np.isin(packet['sourceObjectIds'],[7478,7479,7480,7481,7633,7634])
    source_triangles=packet['triangles'][selected].copy();source_triangles[:,:,:2]=source_triangles[:,:,:2]@matrix.T+origin
    port=source_triangles[packet['sourceObjectIds'][selected]==7634]
    source=np.asarray(old['sourceVerticesSvg']);target=np.asarray(old['targetVerticesSvg']);cells=np.asarray(old['triangles'])
    # Existing source constraints are read from the sealed region vertices.
    # Re-entering their pre-serialization decimal constants would introduce
    # extra parallel lines only a few ulps away from the actual region edges.
    constraint_reuse=[]
    def existing(axis,value):
        values=np.unique(source[:,axis]);actual=float(values[np.argmin(abs(values-value))])
        assert abs(actual-value)<1e-10
        constraint_reuse.append(dict(axis=axis,authoredConstructionConstant=value,sealedSourceCoordinate=actual,difference=actual-value))
        return actual
    x0=existing(0,234.127158234273);post=existing(0,235.18003569025342);old_join=existing(0,238.01654876212172)
    new_join=float(port[:,:,0].max());corner=existing(0,240.2312494570628);x1=246.
    y0=existing(1,210.38670489944627);low=existing(1,212.454846658574);high=float(port[:,:,1].max());y1=228.
    box=[x0,y0,x1,y1]
    xs=[x0,post,old_join,new_join,corner,x1];ys=[y0,low,existing(1,212.64364320961064),high,y1]
    point_ids={};points=[];mapped=[];new_cells=[];old_parents=[];collapsed=[]
    original_targets={tuple(p):t for p,t in zip(source,target)}
    old_inverse=np.linalg.inv(np.swapaxes(source[cells][:,1:]-source[cells][:,:1],1,2))

    def base(point,parent):
        if tuple(point) in original_targets:
            return original_targets[tuple(point)].copy()
        tri=source[cells[parent]];weights=old_inverse[parent]@(point-tri[0])
        dst=target[cells[parent]]
        return dst[0]+weights@(dst[1:]-dst[0])

    def changed(point,value):
        x,y=point
        if x<=x0 or x>=x1 or y<=y0 or y>=y1:
            return value
        along=float(np.interp(x,[post,new_join,corner],[236.012,238.139,240.797]))
        old_along=float(np.interp(x,[post,old_join,corner],[236.012,238.139,240.797]))
        yweight=float(np.interp(y,[y0,low,high,y1],[0,1,1,0]))
        # The jamb/return X planes stay fixed; only the source130/131 join moves.
        dx=(along-old_along)*yweight if post<x<corner else 0.
        header=float(np.interp(x,[post,new_join],[213.64,216.298]))
        desired=float(np.interp(y,[y0,low,high,y1],[210.45,header,header,228.]))
        xweight=float(np.interp(x,[x0,post,corner,x1],[0,1,1,0]))
        return np.array([value[0]+dx,(1-xweight)*value[1]+xweight*desired])

    def add(rational,parent):
        point=np.array([float(v) for v in rational]);key=tuple(point)
        if key not in point_ids:
            point_ids[key]=len(points);points.append(point);mapped.append(changed(point,base(point,parent)))
        return point_ids[key]

    for parent,cell in enumerate(cells):
        tri=source[cell];polys=[[tuple(Fraction(float(v)) for v in p) for p in tri]]
        # Cut the complete source mesh at each axis constraint. Restricting
        # cuts to overlapping triangles would leave T-junctions on their
        # neighboring triangles outside the finite changed region.
        for axis,values in [(0,xs),(1,ys)]:
            for value in values:
                polys=[part for poly in polys for part in split_polygon(poly,axis,value)]
        for poly in polys:
            for j in range(1,len(poly)-1):
                a,b,c=poly[0],poly[j],poly[j+1]
                determinant=(b[0]-a[0])*(c[1]-a[1])-(b[1]-a[1])*(c[0]-a[0])
                if not determinant:
                    continue
                ids=[add(p,parent) for p in [a,b,c]]
                stored=[tuple(Fraction(float(v)) for v in points[k]) for k in ids]
                sa,sb,sc=stored
                stored_det=(sb[0]-sa[0])*(sc[1]-sa[1])-(sb[1]-sa[1])*(sc[0]-sa[0])
                if not stored_det:
                    collapsed.append(dict(parent=parent,storedVertexIds=ids,
                        exactConstructionAreaNumerator=str(abs(determinant.numerator)),
                        exactConstructionDoubleAreaDenominator=str(determinant.denominator),
                        exactStoredDoubleArea='0'))
                    continue
                new_cells.append(ids);old_parents.append(parent)
    points=np.asarray(points);mapped=np.asarray(mapped);new_cells=np.asarray(new_cells);old_parents=np.asarray(old_parents)
    family=deepcopy(old)
    family.update(sourceVerticesSvg=points.tolist(),targetVerticesSvg=mapped.tolist(),triangles=new_cells.tolist())
    family['reviewedSourceFaces']=sorted(set(family['reviewedSourceFaces'])|set(packet['sourceFaceIds'][selected].tolist()))
    family['objects']=sorted(set(family['objects'])|{7478,7479,7480,7481,7633,7634})
    family['declaredRankOneMappings']=[]
    # Preserve every former exact line cell after subdividing its source triangle.
    for declaration in old.get('declaredRankOneMappings',[]):
        old_rows={row['cell']:row for row in declaration['cells']};old_ids=set(old_rows)
        ids=np.flatnonzero(np.isin(old_parents,list(old_ids)))
        entry=deepcopy(declaration);entry['cells']=[]
        a,b=np.asarray(entry['targetEndpointsSvg'])
        source_origin=np.asarray(entry['sourceOriginSvg']);tangent=np.asarray(entry['sourceTangent']);length=entry['sourceLengthSvg']
        for cell in ids:
            parent=old_parents[cell]
            np.testing.assert_array_equal(points[new_cells[cell]],source[cells[parent]])
            parameters=np.asarray(old_rows[parent]['vertexParameters'])
            entry['cells'].append(dict(cell=int(cell),vertexParameters=parameters.tolist()))
        entry['targetEndpointVertexIds']=[int(np.flatnonzero((mapped==endpoint).all(1))[0]) for endpoint in [a,b]]
        family['declaredRankOneMappings'].append(entry)
    for tag,lower,upper,ends in [('pipe130',post,new_join,[[236.012,213.64],[238.139,216.298]]),
                                 ('pipe131',new_join,corner,[[238.139,216.298],[240.797,216.298]])]:
        tri=points[new_cells]
        inside=(tri[:,:,0].min(1)>=lower)&(tri[:,:,0].max(1)<=upper)&(tri[:,:,1].min(1)>=low)&(tri[:,:,1].max(1)<=high)
        ids=np.flatnonzero(inside);a,b=np.asarray(ends)
        rows=[]
        for cell in ids:
            parameters=(points[new_cells[cell],0]-lower)/(upper-lower)
            mapped[new_cells[cell]]=a+parameters[:,None]*(b-a)
            rows.append(dict(cell=int(cell),vertexParameters=parameters.tolist()))
        endpoints=[int(np.flatnonzero((mapped==endpoint).all(1))[0]) for endpoint in [a,b]]
        family['declaredRankOneMappings'].append(dict(id=tag,targetEndpointVertexIds=endpoints,targetEndpointsSvg=ends,
            sourceOriginSvg=[lower,low],sourceTangent=[1.,0.],sourceLengthSvg=upper-lower,
            sourceEndpointArithmeticSvg=0.,cells=rows))
    family['targetVerticesSvg']=mapped.tolist()
    family['pipe130ProfileProposal']=dict(sourceBox=box,sourceAlong=[post,new_join],sourceNormalBand=[low,high],
        source131Along=[new_join,corner],target130=[[236.012,213.64],[238.139,216.298]],
        sourceJoinReason='Complete lower port tangent extent; full original pipe and port heights retained.',
        sourceObjects=[7478,7479,7480,7481,7633,7634],excludedSeparateObject=3963,
        originalBindingsSha256=sha(bindings_path),sourcePacketSha256=sha(packet_path),
        sourcePartition='Exact rational axis cuts of original stored source cells; no coordinate grid rounding.',
        constructionCellsCollapsedByBinary64Storage=collapsed,
        existingConstraintReuse=constraint_reuse,
        status='Proposal only. No pack or production geometry generated.')
    return family,old,source_triangles,packet['sourceObjectIds'][selected],warp


def main():
    output=REV/'split-pipe130-profile-region-proposal-v5';output.mkdir(exist_ok=False)
    family,old,triangles,owners,warp=declare()
    path=output/'region-declaration.json';path.write_text(json.dumps(family,indent=2)+'\n')
    source=np.asarray(family['sourceVerticesSvg']);target=np.asarray(family['targetVerticesSvg']);cells=np.asarray(family['triangles'])
    mapping=explicit_warp(source,target-source,cells)
    matrix=np.column_stack([warp['projection']['axisU'],warp['projection']['axisV']]);origin=np.asarray(warp['projection']['origin'])
    ws=np.asarray(warp['sourceNativeMeters']).reshape(-1,2)@matrix.T+origin;wt=np.asarray(warp['targetAttackSvg']).reshape(-1,2)
    forward=explicit_warp(ws,wt-ws,np.asarray(warp['triangles']).reshape(-1,3))
    try:topology=verify_region_topology(family,forward)
    except AssertionError as error:topology=dict(passed=False,error=str(error))
    src=source[cells];dst=target[cells]
    cross=lambda x:(x[:,1,0]-x[:,0,0])*(x[:,2,1]-x[:,0,1])-(x[:,1,1]-x[:,0,1])*(x[:,2,0]-x[:,0,0])
    determinant=cross(dst)/cross(src)
    report=dict(topology=topology,minimumRawDeterminant=float(determinant.min()),negativeCells=np.flatnonzero(determinant < -1e-12).tolist(),
        declarationSha256=sha(path),scriptSha256=sha(Path(__file__)),productionMutation=False)
    (output/'proposal-review.json').write_text(json.dumps(report,indent=2)+'\n')
    print(json.dumps(report,indent=2))
    fig,axes=plt.subplots(2,3,figsize=(16,10))
    ends=np.array([[236.012,213.64],[238.139,216.298],[240.797,216.298]])
    for row,z in enumerate([6.781631480113873,8.263667525596553]):
        lines,_=sections(triangles,z)
        # Dense line points show the proposal visually. Exact per-cell section
        # partition/contact checks remain separate from this preview.
        pieces=np.stack([line[0]+np.linspace(0,1,65)[:,None]*(line[1]-line[0]) for line in lines])
        for col in range(2):
            display=pieces if col==0 else mapping.apply(pieces.reshape(-1,2)).reshape(pieces.shape)
            for line in display:axes[row,col].plot(*line.T,color='#ea580c',lw=.7)
            axes[row,col].plot(*ends.T,color='black',lw=2)
            axes[row,col].set_title(('Original source' if col==0 else 'Mapped proposal')+f', Z={z:.6f}m')
        centers=src.mean(1);local=(centers[:,0]>233)&(centers[:,0]<247)&(centers[:,1]>209)&(centers[:,1]<229)
        for cell in cells[local]:axes[row,2].plot(*np.r_[target[cell],target[cell[:1]]].T,color='#94a3b8',lw=.35)
        axes[row,2].plot(*ends.T,color='black',lw=2);axes[row,2].set_title('Target region cell edges')
        for ax in axes[row]:ax.set_xlim(233,247);ax.set_ylim(223,209);ax.set_aspect('equal');ax.grid(alpha=.15)
    fig.suptitle('Connected pipe130 profile-band proposal. Original source heights unchanged. No pack bake.')
    fig.tight_layout();fig.savefig(output/'profile-preview.png',dpi=160);plt.close(fig)


if __name__=='__main__':main()

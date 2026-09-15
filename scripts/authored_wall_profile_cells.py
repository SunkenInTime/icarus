"""Split source profiles at endpoint clamps and display-warp cell boundaries."""
import numpy as np

def validated_frame(frame):
    """Reject ambiguous scale/shear so along coordinates remain SVG distances."""
    values={key:np.asarray(frame[key],dtype=float) for key in ['origin','tangent','normal']}
    if any(value.shape!=(2,) or not np.isfinite(value).all() for value in values.values()):
        raise ValueError('Wall frame must contain finite two-dimensional vectors')
    tangent,normal=values['tangent'],values['normal']
    matrix=np.column_stack((tangent,normal))
    if not np.allclose(matrix.T@matrix,np.eye(2),atol=1e-10,rtol=0) or abs(np.linalg.det(matrix)-1)>1e-10:
        raise ValueError('Wall frame must be orthonormal and right-handed')
    return values

def family_frames(family):
    if 'sourceFrame' in family or 'targetFrame' in family:
        if 'sourceFrame' not in family or 'targetFrame' not in family:
            raise ValueError('Both source and target wall frames are required')
        return validated_frame(family['sourceFrame']),validated_frame(family['targetFrame'])
    axis=family['axis']
    if axis not in (0,1):raise ValueError('Legacy wall axis must be zero or one')
    tangent=np.eye(2)[axis];normal=np.array([-tangent[1],tangent[0]])
    source=dict(origin=[0,0],tangent=tangent,normal=normal)
    target=dict(source);target['origin']=np.array([0.,0.]);target['origin'][1-axis]=family['fixed']
    return validated_frame(source),validated_frame(target)

def partition_linear(poly,origin,direction,breakpoints):
    """Carry source barycentrics through a cut in any linear along coordinate."""
    result=[];remaining=list(poly)
    for value in sorted(set(breakpoints)):
        if not remaining:break
        coords=(np.array(remaining)[:,:2]-origin)@direction
        if value<=coords.min() or value>=coords.max():continue
        left=[];right=[]
        for a,b in zip(remaining,remaining[1:]+remaining[:1]):
            av=float((a[:2]-origin)@direction-value);bv=float((b[:2]-origin)@direction-value)
            (right if av>=0 else left).append(a)
            if (av>=0)!=(bv>=0):
                q=a+(b-a)*av/(av-bv);left.append(q);right.append(q)
        if len(left)>=3:result.append(np.array(left))
        remaining=right
    if len(remaining)>=3:result.append(np.array(remaining))
    return result

def partition(poly,axis,breakpoints):
    return partition_linear(poly,np.zeros(2),np.eye(2)[axis],breakpoints)

def wall_breakpoints(warp,axis,fixed,lower,upper):
    """Backward-compatible axis-aligned target wall wrapper."""
    _,frame=family_frames(dict(axis=axis,fixed=fixed))
    return frame_wall_breakpoints(warp,frame,lower,upper)

def frame_wall_breakpoints(warp,target_frame,lower,upper):
    """All target-cell intersections for an arbitrary straight authored wall."""
    frame=validated_frame(target_frame)
    points=warp.points[warp.tri.simplices]-frame['origin']
    along=points@frame['tangent'];across=points@frame['normal']
    admitted=(across.min(1)<=0)&(across.max(1)>=0)&(along.min(1)<=upper)&(along.max(1)>=lower)
    result=[]
    for tri in np.stack((along,across),axis=2)[admitted]:
        for a,b in zip(tri,np.roll(tri,-1,axis=0)):
            av=a[1];bv=b[1]
            if av==0:result.append(float(a[0]))
            if av*bv<0:result.append(float(a[0]+(b[0]-a[0])*av/(av-bv)))
    return sorted(set(x for x in result if lower<x<upper))

def normalized_fragments(data,family,warp,discarded=None):
    """Return canonical XY/Z/barycentric polygons, each in one target W cell."""
    source_frame,target_frame=family_frames(family)
    s0,s1=family['sourceAlong'];t0,t1=family['targetAlong']
    if not np.isfinite([s0,s1,t0,t1]).all() or s1<=s0 or t1<=t0:
        raise ValueError('Wall along ranges must be finite and increasing')
    breaks=family['displayWarpBreakpoints']
    output=[]
    for source_part in partition_linear(data,source_frame['origin'],source_frame['tangent'],[s0,s1]):
        canonical=source_part.copy()
        along=(canonical[:,:2]-source_frame['origin'])@source_frame['tangent']
        mapped=t0+np.clip((along-s0)/(s1-s0),0,1)*(t1-t0)
        canonical[:,:2]=target_frame['origin']+mapped[:,None]*target_frame['tangent']
        for part in partition_linear(canonical,target_frame['origin'],target_frame['tangent'],breaks):
            if np.ptp((part[:,:2]-target_frame['origin'])@target_frame['tangent'])<1e-13:
                if discarded is not None:discarded.append(part)
                continue
            cell=int(warp.tri.find_simplex(part[:,:2].mean(0)))
            if cell<0:raise ValueError('Canonical wall fragment lies outside display W')
            weights=target_barycentrics(part[:,:2],warp,cell)
            if weights.min() < -1e-8:raise ValueError('Canonical fragment crosses its assigned target W cell')
            output.append((part,cell))
    return output

def target_barycentrics(xy,warp,cell):
    tri=warp.points[warp.tri.simplices[cell]]
    return np.linalg.solve(np.vstack((tri.T,np.ones(3))),np.column_stack((xy,np.ones(len(xy)))).T).T

def inverse_in_cell(xy,warp,cell):
    ids=warp.tri.simplices[cell]
    return target_barycentrics(xy,warp,cell)@(warp.points[ids]+warp.delta[ids])

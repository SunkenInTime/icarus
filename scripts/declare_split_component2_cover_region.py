"""Connected body/cover datum proposal with exact rounded-corner collapse."""
import copy,json,gzip
import numpy as np
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
from matplotlib.collections import LineCollection
from build_split_connected_tower import REV
from authored_region_cells import region_fragments
from tactical_alignment_composite import explicit_warp
from render_split_remaining_corner_families import sections

def grid(xs,ys,mapping):
    source=[];target=[];cells=[];nx=len(xs)
    for row,y in enumerate(ys):
        for col,x in enumerate(xs):
            source.append([x,y]);target.append([x,y] if row in [0,len(ys)-1] or col in [0,nx-1] else mapping(x,y))
    for row in range(len(ys)-1):
        for col in range(nx-1):
            a=row*nx+col;b=a+1;c=a+nx;d=c+1;cells.extend([[a,b,d],[a,d,c]])
    source=np.array(source);target=np.array(target);cells=np.array(cells)
    def area(p):
        a=p[cells[:,1]]-p[cells[:,0]];b=p[cells[:,2]]-p[cells[:,0]];return a[:,0]*b[:,1]-a[:,1]*b[:,0]
    assert area(source).min()>0 and area(target).min()>=-1e-9
    return dict(sourceVerticesSvg=source.tolist(),targetVerticesSvg=target.tolist(),triangles=cells.tolist(),box=[xs[0],ys[0],xs[-1],ys[-1]],identityOuterBoundary=True)

def declarations():
    packet=REV/'split-component2-cover-review-v1';raw=np.load(packet/'cover-source.npz');tri=raw['sourceTrianglesSvgZ'];xy=tri[:,:,:2].reshape(-1,2);lo=xy.min(0);hi=xy.max(0)
    left,right=lo[0],hi[0];front=hi[1]
    front_points=xy[np.isclose(xy[:,1],front,atol=1e-9,rtol=0)];inner_left=front_points[:,0].min();inner_right=front_points[:,0].max()
    side_points=xy[np.isclose(xy[:,0],left,atol=1e-9,rtol=0)|np.isclose(xy[:,0],right,atol=1e-9,rtol=0)];inner_front=side_points[:,1].max();rear_max=side_points[side_points[:,1]<lo[1]+.01,1].max();rear=136.22373887267753
    old=next(f for f in json.loads((REV/'split-wall-family-normalized-candidate-v17/bindings.json').read_text())['families'] if f['edge']==20082);body=copy.deepcopy(old)
    old_source=np.array(old['sourceVerticesSvg']);old_target=np.array(old['targetVerticesSvg']);xs=sorted(set(old_source[:,0])|{left,right});ys=sorted(set(old_source[:,1]));old_nx=len(set(old_source[:,0]));target_ys=old_target.reshape(-1,old_nx,2)[:,2,1]
    bx=old['sourceSurfaceBands'];kx=[bx['leftPrimary'],left,right,bx['rightPrimary']];tx=[392.311,417.298,424.741,424.741]
    body.update(grid(xs,ys,lambda x,y:[float(np.interp(x,kx,tx)),float(np.interp(y,ys,target_ys))]));body['sharedCoverDatum']=dict(sourceLeftX=left,sourceRightX=right,targetLeftX=417.298,targetRightX=424.741,sourceContactY=rear,targetContactY=134.959)
    body['status']='Revised source tangent knots for attached cover, proposal only.'
    xs=[left-3,left-1e-6,left,inner_left,inner_right,right,right+1e-6,right+3];ys=sorted(set([rear-3,rear-1e-6,rear,lo[1],rear_max,inner_front,front,front+1e-6,front+3]))
    def mapping(x,y):
        u=float(np.clip((y-rear_max)/(inner_front-rear_max),0,1))
        top_x=float(np.interp(x,[left,right],[417.298,424.741]));front_x=float(np.interp(x,[inner_left,inner_right],[417.298,424.741]))
        return [(1-u)*top_x+u*front_x,134.959+u*(142.933-134.959)]
    cover=dict(edge=205803,mappingType='piecewise-affine-region-v1',objects=[5803],reviewedSourceFaces=raw['sourceFaceIds'].tolist(),role='Reviewed attached lower cover, original Z/UV retained; rounded front corners collapse to authored sharp corners without adding height coverage.',reviewedAuthoredSpans=[dict(completeSpan=205830+i,legacyStraightEdgeIndex=None,startSvg=a,endSvg=b) for i,(a,b) in enumerate([([417.298,134.959],[417.298,142.933]),([417.298,142.933],[424.741,142.933]),([424.741,142.933],[424.741,134.959])])],sourceCornerEnvelope=dict(left=left,right=right,rear=rear,rearMaximum=rear_max,front=front,frontFlatLeft=inner_left,frontFlatRight=inner_right,sideFlatEnd=inner_front),sharedBodyDatum=body['sharedCoverDatum'],status='Proposal only; root source/region review required.')
    cover.update(grid(xs,ys,mapping));return body,cover

def main():
    out=REV/'split-component2-cover-region-proposal-v1';out.mkdir(exist_ok=True);body,cover=declarations();(out/'region-declarations.json').write_text(json.dumps(dict(body=body,cover=cover),indent=2))
    w=json.loads(gzip.decompress((REV/'display-warps-v1/split.display-warp.json.gz').read_bytes()));m=np.column_stack((w['projection']['axisU'],w['projection']['axisV']));o=np.array(w['projection']['origin']);s=np.array(w['sourceNativeMeters']).reshape(-1,2)@m.T+o;t=np.array(w['targetAttackSvg']).reshape(-1,2);unwarp=explicit_warp(t,s-t,np.array(w['triangles']).reshape(-1,3));raw=np.load(REV/'split-component2-cover-review-v1/cover-source.npz');original=raw['sourceTrianglesSvgZ'];mapped=[]
    for tri in original:
        for part,_,_ in region_fragments(np.column_stack((tri,np.eye(3))),cover,unwarp):
            for i in range(1,len(part)-1):mapped.append(part[[0,i,i+1],:3])
    mapped=np.array(mapped);fig,axes=plt.subplots(1,3,figsize=(17,6))
    for ax,z in zip(axes,[.75,1.75,3.5]):
        for label,mesh,color in [('Original cover',original,'#dc2626'),('Proposed mapped cover',mapped,'#16a34a')]:
            lines,_=sections(mesh,z);ax.add_collection(LineCollection(lines,colors=color,lw=3 if color=='#16a34a' else 1.8,label=label))
        for span in cover['reviewedAuthoredSpans']:ax.plot(*np.array([span['startSvg'],span['endSvg']]).T,color='#111827',lw=1)
        ax.plot([413,424.741],[134.959,134.959],color='#111827',lw=2);ax.set_xlim(414,427);ax.set_ylim(146,133);ax.set_aspect('equal');ax.grid(alpha=.2);ax.set_title(f'Absolute source Z={z}m');ax.legend(fontsize=8)
    fig.suptitle('Connected cover proposal: three exact authored fronts and shared body contact datum. Source heights remain unchanged.');fig.tight_layout();fig.savefig(out/'cover-region-source-preview.png',dpi=160);plt.close(fig);print(out)

if __name__=='__main__':main()

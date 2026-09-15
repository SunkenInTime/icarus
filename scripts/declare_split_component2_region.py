"""One connected region proposal for the reviewed tower-battery shell and plate."""
import hashlib,json,gzip
import numpy as np
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
from matplotlib.collections import LineCollection
from build_split_connected_tower import REV
from authored_region_cells import region_fragments
from tactical_alignment_composite import explicit_warp
from render_split_remaining_corner_families import sections

def declaration():
    folder=REV/'split-component2-source-review-v1';path=folder/'full-objects-source-packet.npz';raw=np.load(path);tri=raw['sourceSvgTriangles'];lo=tri[:,:,:2].min((0,1));hi=tri[:,:,:2].max((0,1))
    left,right=390.7150310866566,423.94680343336705;top,bottom=108.95023593994432,134.80980050332948
    target_box=[392.311,108.909,424.741,134.959]
    xs=[lo[0]-2,lo[0]-1e-6,left,right,hi[0]+1e-6,hi[0]+2]
    ys=[lo[1]-2,lo[1]-1e-6,108.85639694009262,top,bottom,136.22373887267753,hi[1]+1e-6,hi[1]+2]
    source=[];target=[];nx=len(xs)
    for row,y in enumerate(ys):
        for col,x in enumerate(xs):
            source.append([x,y]);mapped=[target_box[0]+np.clip((x-left)/(right-left),0,1)*(target_box[2]-target_box[0]),target_box[1]+np.clip((y-top)/(bottom-top),0,1)*(target_box[3]-target_box[1])]
            target.append([x,y] if row in [0,len(ys)-1] or col in [0,nx-1] else mapped)
    triangles=[]
    for row in range(len(ys)-1):
        for col in range(nx-1):
            a=row*nx+col;b=a+1;c=a+nx;d=c+1;triangles.extend([[a,b,d],[a,d,c]])
    source=np.array(source);target=np.array(target);cells=np.array(triangles)
    def areas(points):
        u=points[cells[:,1]]-points[cells[:,0]];v=points[cells[:,2]]-points[cells[:,0]];return u[:,0]*v[:,1]-u[:,1]*v[:,0]
    assert areas(source).min()>0 and areas(target).min()>=-1e-10
    return dict(edge=20082,mappingType='piecewise-affine-region-v1',completeSpans=[82,83,84,85],sourceVerticesSvg=source.tolist(),targetVerticesSvg=target.tolist(),triangles=triangles,objects=[5866,5801],reviewedSourceFaces=raw['originalFaceIds'].tolist(),box=[xs[0],ys[0],xs[-1],ys[-1]],identityOuterBoundary=True,role='Reviewed whole connected tower-battery shell and attached barrier plate. Shared source corner, roof, cap and inset-panel coordinates use one field. No added height coverage.',sourcePacketSha256=hashlib.sha256(path.read_bytes()).hexdigest(),sourceSurfaceBands=dict(leftPrimary=left,rightPrimary=right,topPrimary=108.85639694009262,topInset=top,bottomInset=bottom,bottomPrimary=136.22373887267753,wholeAssemblyBounds=[lo.tolist(),hi.tolist()]),targetAuthoredRectangle=target_box,status='Declaration and source preview only; no candidate pack baked.',validation=dict(sourceCells=len(cells),collapsedTargetCells=int((abs(areas(target))<1e-10).sum()),minSourceDoubleArea=float(areas(source).min()),minTargetDoubleArea=float(areas(target).min())))

def main():
    out=REV/'split-component2-connected-region-proposal-v1';out.mkdir(exist_ok=True);family=declaration();(out/'region-declaration.json').write_text(json.dumps(family,indent=2))
    w=json.loads(gzip.decompress((REV/'display-warps-v1/split.display-warp.json.gz').read_bytes()));m=np.column_stack((w['projection']['axisU'],w['projection']['axisV']));o=np.array(w['projection']['origin']);s=np.array(w['sourceNativeMeters']).reshape(-1,2)@m.T+o;t=np.array(w['targetAttackSvg']).reshape(-1,2);unwarp=explicit_warp(t,s-t,np.array(w['triangles']).reshape(-1,3))
    raw=np.load(REV/'split-component2-source-review-v1/full-objects-source-packet.npz');original=raw['sourceSvgTriangles'];mapped=[];faceids=[]
    for fid,tri in zip(raw['originalFaceIds'],original):
        for part,_,_ in region_fragments(np.column_stack((tri,np.eye(3))),family,unwarp):
            for i in range(1,len(part)-1):mapped.append(part[[0,i,i+1],:3]);faceids.append(int(fid))
    mapped=np.array(mapped);np.savez_compressed(out/'source-preview.npz',originalFaceIds=raw['originalFaceIds'],sourceTriangles=original,mappedSourceFaceIds=faceids,mappedTriangles=mapped)
    fig,axes=plt.subplots(2,3,figsize=(18,12));cells=np.array(family['triangles'])
    for ax,points,title in zip(axes[0,:2],[np.array(family['sourceVerticesSvg']),np.array(family['targetVerticesSvg'])],['One shared source region','Displayed region with exact four corners']):
        ax.triplot(points[:,0],points[:,1],cells,color='#64748b',lw=.6);ax.set_aspect('equal');ax.invert_yaxis();ax.set_title(title);ax.grid(alpha=.2)
    axes[0,2].axis('off');axes[0,2].text(0,1,'Proposal only, no pack bake.\n\nExact3452 source faces.\nAll original heights retained.\nNo height extrusion or opening fill.\n\nFront, backing, inset panel and cap\nshare coordinates throughout.\n\nOnly reviewed wall-depth bands collapse.\nRoof and attached overhangs are included.',fontsize=13,va='top')
    box=family['targetAuthoredRectangle'];outline=np.array([[box[0],box[1]],[box[0],box[3]],[box[2],box[3]],[box[2],box[1]],[box[0],box[1]]])
    for ax,z in zip(axes[1],[1.75,5.,8.25]):
        for label,mesh,color in [('Original source',original,'#dc2626'),('Region mapped source',mapped,'#16a34a')]:
            lines,_=sections(mesh,z);ax.add_collection(LineCollection(lines,colors=color,lw=1.3,label=label))
        ax.plot(*outline.T,color='#111827',lw=2);ax.set_xlim(386,429);ax.set_ylim(145,104);ax.set_aspect('equal');ax.grid(alpha=.2);ax.set_title(f'Absolute source Z={z}m');ax.legend(fontsize=8)
    fig.suptitle('Split component2, complete spans82–85, connected shell/plate mapping proposal. Black is authored wall.',fontsize=13);fig.tight_layout();fig.savefig(out/'connected-region-source-preview.png',dpi=160);plt.close(fig);print(out)

if __name__=='__main__':main()

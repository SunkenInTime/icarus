"""Connected component7 field proposal, with finite identity boundaries."""
import gzip,json
import numpy as np
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
from matplotlib.collections import LineCollection
from build_split_connected_tower import REV
from declare_split_component2_cover_region import grid
from build_split_normalized_wall_families import cut
from authored_region_cells import region_fragments
from tactical_alignment_composite import explicit_warp
from render_split_remaining_corner_families import sections

def declarations():
    proposal=json.loads(gzip.decompress((REV/'split-connected-contour-proposals-v2/component-7.json.gz').read_bytes()));raw=np.load(REV/'split-component7-source-review-v1/full-source-context.npz');byspan={s['completeSpan']:s for s in proposal['spans']}
    def band(span,plane,axis):
        tri=np.array(byspan[span]['planes'][plane]['sourceClippedTrianglesSvgZ']);return [float(tri[:,:,axis].min()),float(tri[:,:,axis].max())]
    xbands=[dict(spans=[190],source=band(190,0,0),target=91.9403),dict(spans=[192],source=band(192,0,0),target=103.636),dict(spans=[200],source=[114.07940259974146,115.08698618373373],target=114.269),dict(spans=[194],source=[band(194,0,0)[0],119.0191098483903],target=118.522),dict(spans=[198],source=band(198,0,0),target=145.635),dict(spans=[196],source=[173.7312884607353,band(196,2,0)[1]],target=173.454)]
    ybands=[dict(spans=[193],source=band(193,0,1),target=102.529),dict(spans=[191],source=[110.53306064659694,band(191,1,1)[1]],target=110.504),dict(spans=[195],source=[132.3141782526651,band(195,0,1)[1]],target=131.769),dict(spans=[201],source=[136.22367921660646,136.22379852874866],target=134.959),dict(spans=[197],source=band(197,0,1),target=156.224),dict(spans=[199],source=[180.45546434281476,181.9488944269132],target=180.147)]
    def knots(bands,lower,upper):
        points={lower:lower,upper:upper}
        for b in bands:
            for q in b['source']:points[q]=b['target']
        values=sorted(points);return values,[points[x] for x in values]
    xs,tx=knots(xbands,88.,185.);ys,ty=knots(ybands,100.,185.5)
    family=dict(edge=200190,mappingType='piecewise-affine-region-v1',objects=sorted(np.unique(raw['sourceObjectIds']).tolist()),reviewedSourceFaces=raw['sourceFaceIds'].tolist(),reviewedAuthoredSpans=[dict(completeSpan=s['completeSpan'],legacyStraightEdgeIndex=s['legacyStraightEdgeIndex'],startSvg=s['authoredEndpoints'][0],endSvg=s['authoredEndpoints'][1]) for s in proposal['spans']],sourceProfileBands=dict(x=xbands,y=ybands),role='PROPOSAL: connected hostel/tower/balcony/wrap surfaces within a finite window. Entire source IDs are bound, but fragments outside the window remain unchanged. Height-specific gaps are not extruded.',status='Source region proposal only. Wavy wrap bands and local roof/depth ownership require root review before bake.',identityOutsideReason='The neighboring source wall begins atx187.4148 and remains outside right185 boundary; distant hostel pieces left of88 and tower geometry below185.5 remain source-identical.',frozenClearCorridorControls='split-component7-source-review-v1/continuation-standing-source-rays.json')
    family.update(grid(xs,ys,lambda x,y:[float(np.interp(x,xs,tx)),float(np.interp(y,ys,ty))]));return family

def main():
    out=REV/'split-component7-connected-region-proposal-v1';out.mkdir(exist_ok=True);family=declarations();(out/'region-declaration.json').write_text(json.dumps(family,indent=2));w=json.loads(gzip.decompress((REV/'display-warps-v1/split.display-warp.json.gz').read_bytes()));m=np.column_stack((w['projection']['axisU'],w['projection']['axisV']));o=np.array(w['projection']['origin']);s=np.array(w['sourceNativeMeters']).reshape(-1,2)@m.T+o;t=np.array(w['targetAttackSvg']).reshape(-1,2);unwarp=explicit_warp(t,s-t,np.array(w['triangles']).reshape(-1,3));raw=np.load(REV/'split-component7-source-review-v1/full-source-context.npz');original=raw['trianglesSvgSourceZ'];mapped=[]
    for tri in original:
        inside,outside=cut(list(np.column_stack((tri,np.eye(3)))),family['box']);parts=[np.array(x) for x in outside]
        if len(inside)>=3:parts.extend(p for p,_,_ in region_fragments(np.array(inside),family,unwarp))
        for part in parts:
            for i in range(1,len(part)-1):mapped.append(part[[0,i,i+1],:3])
    mapped=np.array(mapped);fig,axes=plt.subplots(2,3,figsize=(18,12));points=np.array(family['sourceVerticesSvg']);target=np.array(family['targetVerticesSvg']);cells=np.array(family['triangles'])
    for ax,xy,title in zip(axes[0,:2],[points,target],['Shared source cells','Proposed displayed cells']):ax.triplot(xy[:,0],xy[:,1],cells,color='#64748b',lw=.35);ax.set_aspect('equal');ax.invert_yaxis();ax.set_title(title)
    axes[0,2].axis('off');axes[0,2].text(0,1,'Proposal only.\nFinite identity window protects\nneighboring source wall pieces.\n\nLow and upper source openings remain.\nWrap and door keep original Z.\n\nNo wall-height extrusion.\nNo pack bake.',va='top',fontsize=14)
    for ax,z in zip(axes[1],[5.75,9.75,11.75]):
        for label,mesh,color in [('Original source',original,'#dc2626'),('Region proposal',mapped,'#16a34a')]:
            lines,_=sections(mesh,z);ax.add_collection(LineCollection(lines,colors=color,lw=1.2,label=label))
        for span in family['reviewedAuthoredSpans']:ax.plot(*np.array([span['startSvg'],span['endSvg']]).T,color='#111827',lw=1)
        ax.set_xlim(85,190);ax.set_ylim(190,95);ax.set_aspect('equal');ax.grid(alpha=.2);ax.set_title(f'Absolute source Z={z}m');ax.legend(fontsize=8)
    fig.suptitle('Component7 connected source-profile proposal. Original height gaps remain, black is authored contour.');fig.tight_layout();fig.savefig(out/'connected-source-profile-preview.png',dpi=160);plt.close(fig);print(out)

if __name__=='__main__':main()

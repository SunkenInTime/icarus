"""Whole source wall context for the remaining Boat V5 plinth contacts."""
import json
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
from mpl_toolkits.mplot3d.art3d import Poly3DCollection
import numpy as np
from prepare_ascent_connected_corners import ROOT,REV
from native_compact_wall_profiles import sha


def main():
    output=REV/'ascent-boat-wall-plinth-review-v1';output.mkdir(exist_ok=True)
    path=ROOT/'supplemented-v2/world/ascent/geometry.npz';raw=np.load(path);meta=json.loads(path.with_suffix('.json').read_text());o=meta['objects'][7556];ids=np.arange(o['firstFace'],o['firstFace']+o['faceCount']);tri=raw['points'][raw['faces'][ids]].astype(float)
    trace_path=REV/'ascent-connected-boat-candidate-v5/frozen-render-contact-sources.json';trace=json.loads(trace_path.read_text());hit_ids=sorted({s['faceChain'][-1] for row in trace['records'][:4] for s in row['samples'] if s.get('sourceObject')==7556 and s.get('normalOffsetSvg',0)>1e-5});hits=raw['points'][raw['faces'][hit_ids]].astype(float)
    affine=np.asarray(json.loads((ROOT/'tactical-alignment-sides-v1/ascent.json').read_text())['nativeToAttackSvg']);svg=tri[:,:,:2]@affine[:,:2].T+affine[:,2];hit_svg=hits[:,:,:2]@affine[:,:2].T+affine[:,2]
    fig=plt.figure(figsize=(14,7));ax=fig.add_subplot(121,projection='3d');plan=fig.add_subplot(122)
    ax.add_collection3d(Poly3DCollection(tri,facecolor='#94a3b8',edgecolors='#64748b',alpha=.15,linewidths=.3));ax.add_collection3d(Poly3DCollection(hits,facecolor='#f59e0b',edgecolors='#92400e',alpha=.8,linewidths=.8))
    lo=tri.min((0,1));hi=tri.max((0,1));ax.set_xlim(lo[0]-.2,hi[0]+.2);ax.set_ylim(lo[1]-.2,hi[1]+.2);ax.set_zlim(0,5);ax.set_box_aspect([hi[0]-lo[0],hi[1]-lo[1],5]);ax.view_init(elev=25,azim=-135);ax.set_xlabel('Original X, m');ax.set_ylabel('Original Y, m');ax.set_zlabel('Original Z, m')
    for t in svg:plan.plot(*np.r_[t,t[:1]].T,color='#94a3b8',linewidth=.3)
    for t in hit_svg:plan.plot(*np.r_[t,t[:1]].T,color='#c2410c',linewidth=1)
    plan.axvline(svg[:,:,0].min(),color='#0891b2',linestyle='--',label='Complete source front extent');plan.axhline(svg[:,:,1].min(),color='#0891b2',linestyle='--');plan.set_aspect('equal');plan.invert_yaxis();plan.set_xlabel('Source SVG X');plan.set_ylabel('Source SVG Y');plan.legend()
    fig.suptitle('Ascent CourtyardWall7556: remaining standing contacts are on its low plinth\nOrange exact frozen first-hit faces; gray complete588-face source wall. Upper wall continues beyond the3D crop.');fig.tight_layout();fig.savefig(output/'source-context.png',dpi=160);plt.close(fig)
    report=dict(geometrySha256=sha(path),traceSha256=sha(trace_path),sourceObject=7556,path=o['path'],originalSourceFaceIds=ids.tolist(),contactSourceFaceIds=hit_ids,sourceSvgBounds=[svg.min((0,1)).tolist(),svg.max((0,1)).tolist()],sourceZRange=[float(tri[:,:,2].min()),float(tri[:,:,2].max())],scope='Source context only; whole wall normal-depth bands proposed without height extrusion or unrelated pole inclusion.')
    (output/'review.json').write_text(json.dumps(report,indent=2)+'\n');print(output)


if __name__=='__main__':main()

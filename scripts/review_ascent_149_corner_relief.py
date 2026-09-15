"""Two complete end-relief strips on the already reviewed MidWallA assembly."""
import json
from pathlib import Path
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
from mpl_toolkits.mplot3d.art3d import Poly3DCollection
import numpy as np
from native_compact_wall_profiles import sha
from prepare_ascent_connected_corners import ROOT,REV


def main():
    out=REV/'ascent-149-corner-relief-review-v1';out.mkdir(exist_ok=True)
    path=ROOT/'supplemented-v2/world/ascent/geometry.npz';raw=np.load(path);metadata=json.loads(path.with_suffix('.json').read_text());obj=metadata['objects'][8034]
    affine=np.asarray(json.loads((ROOT/'tactical-alignment-sides-v1/ascent.json').read_text())['nativeToAttackSvg'])
    object_ids=np.arange(obj['firstFace'],obj['firstFace']+obj['faceCount']);xyz=raw['points'][raw['faces'][object_ids]].astype(float);xyz[:,:,:2]=xyz[:,:,:2]@affine[:,:2].T+affine[:,2]
    groups=[]
    for ids,target_x in [(np.arange(2964376,2964400),171.5),(np.arange(2964400,2964424),169.5)]:
        assert np.isin(ids,object_ids).all()
        tri=raw['points'][raw['faces'][ids]].astype(float);tri[:,:,:2]=tri[:,:,:2]@affine[:,:2].T+affine[:,2]
        lo=tri.min((0,1));hi=tri.max((0,1));context=xyz[(xyz.min(1)<=hi+[.5,.5,.2]).all(1)&(xyz.max(1)>=lo-[.5,.5,.2]).all(1)]
        fig=plt.figure(figsize=(12,6));a=fig.add_subplot(121,projection='3d');b=fig.add_subplot(122)
        a.add_collection3d(Poly3DCollection(context,facecolor='#94a3b8',alpha=.16,edgecolors='#64748b',linewidths=.3));a.add_collection3d(Poly3DCollection(tri,facecolor='#f59e0b',alpha=.7,edgecolors='#92400e',linewidths=.5))
        for t in context:b.plot(*np.r_[t[:,:2],t[:1,:2]].T,color='#94a3b8',linewidth=.4)
        for t in tri:b.plot(*np.r_[t[:,:2],t[:1,:2]].T,color='#c2410c',linewidth=1)
        for i,setlim in enumerate([a.set_xlim,a.set_ylim,a.set_zlim]):setlim(lo[i]-.1,hi[i]+.1)
        a.set_xlabel('Source SVG X');a.set_ylabel('Source SVG Y');a.set_zlabel('Original source Z, m');a.set_box_aspect([1,2,3]);a.view_init(elev=22,azim=-65)
        b.set_xlim(lo[0]-.15,hi[0]+.15);b.set_ylim(hi[1]+.15,lo[1]-.15);b.set_aspect('equal');b.set_xlabel('Source SVG X');b.set_ylabel('Source SVG Y')
        fig.suptitle(f'Ascent MidWallA8034: complete24-face end-relief strip near authored X{target_x}\nOrange original faces; gray same source assembly. No full-height extrusion.');fig.tight_layout();fig.savefig(out/f'corner-{target_x:g}.png',dpi=160);plt.close(fig)
        groups.append(dict(sourceObject=8034,path=obj['path'],originalSourceFaceIds=ids.tolist(),authoredNormalAxis=0,authoredCoordinate=target_x,sourceBoundsSvgZ=[lo.tolist(),hi.tolist()],sourceDepthRange=[float(lo[0]),float(hi[0])],sourceTriangleSvgZ=tri.tolist()))
    (out/'review.json').write_text(json.dumps(dict(geometrySha256=sha(path),metadataSha256=sha(path.with_suffix('.json')),sourceObject=8034,groups=groups,scope='Exact source end-relief strips. Both belong to the already reviewed connected MidWallA assembly. Proposed normal-depth registration retains each source triangle height and tangent extent.'),indent=2)+'\n')
    print(out)


if __name__=='__main__':main()

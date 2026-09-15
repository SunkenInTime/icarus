"""Read-only raw source comparison of Icebox wall 3706 and attached strip 2831."""
import gzip
import hashlib
import json
from pathlib import Path

import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
from mpl_toolkits.mplot3d.art3d import Poly3DCollection
import numpy as np
import shapely

from audit_tactical_target_rays import ReferenceModel
from build_global_tactical_candidate import GroundField
from tactical_alignment_composite import explicit_warp

REV = Path('E:/IcarusWorldAudit/2026-09-06/tactical-visibility-revision')


def run():
    out = REV / 'wall-contact-icebox-candidate-v1'
    pack = REV / 'full-height-input-v1/icebox/icebox.height.bin.gz'
    raw = ReferenceModel(pack)
    ids = np.load(pack.parent / 'source-correspondence.npz')['sourceFaces']
    snow_ids = np.flatnonzero((ids >= 1185315) & (ids < 1185681))
    wall_ids = np.flatnonzero((ids >= 1617620) & (ids < 1617976))
    snow = raw.arrays['vertices'][raw.arrays['faces'][snow_ids]]
    wall = raw.arrays['vertices'][raw.arrays['faces'][wall_ids]]
    field = GroundField(REV / 'global-ground-complete-v2/icebox/icebox.tactical-ground.json.gz')
    wpath = REV / 'display-warps-v1/icebox.display-warp.json.gz'
    w = json.loads(gzip.decompress(wpath.read_bytes()))
    source = np.array(w['sourceNativeMeters']).reshape(-1, 2)
    target = np.array(w['targetAttackSvg']).reshape(-1, 2)
    ix = np.array(w['triangles']).reshape(-1, 3)
    forward = explicit_warp(source, target-source, ix)
    sv = snow.reshape(-1, 3)
    displayed = forward.apply(sv[:, :2]).reshape(-1, 3, 2)
    ground = field.heights(sv[:, :2])
    relative = sv[:, 2]-ground
    np.savez_compressed(out/'snow2831-source-and-svg-packet.npz', snowTriangles=snow,
                        wallTriangles=wall, snowFullFaceIds=snow_ids,
                        snowOriginalFaceIds=ids[snow_ids], wallFullFaceIds=wall_ids,
                        wallOriginalFaceIds=ids[wall_ids], displayedSnowXY=displayed,
                        groundAtSnowVertices=ground.reshape(-1,3))
    # Clip actual coplanar wall triangles in Y/Z only for this close view.
    wall_parts = []
    for tri in wall:
        if np.max(abs(tri[:, 0]+47)) > .0001:
            continue
        polygon = shapely.Polygon(tri[:, 1:])
        for part in shapely.get_parts(polygon.intersection(shapely.box(-23.1, 1, -22.2, 5.1))):
            if part.geom_type == 'Polygon':
                yz=np.array(part.exterior.coords)
                wall_parts.append(np.c_[np.full(len(yz),-47),yz])
    sections=[]
    for tri in snow:
        hits=[]
        for a,b in zip(tri,np.roll(tri,-1,axis=0)):
            if (a[2]-2.75)*(b[2]-2.75)<0:
                hits.append(a[:2]+(b[:2]-a[:2])*(2.75-a[2])/(b[2]-a[2]))
        if len(hits)==2:sections.append(np.array(hits))
    plt.style.use('dark_background')
    fig=plt.figure(figsize=(12,7),layout='constrained')
    ax=fig.add_subplot(121,projection='3d')
    ax.add_collection3d(Poly3DCollection(wall_parts,facecolors='#B27C40',alpha=.35,edgecolors='none'))
    ax.add_collection3d(Poly3DCollection(snow,facecolors='#00dfba',alpha=.85,edgecolors='#00786b',linewidths=.15))
    ax.plot([-47,-46.7],[-22.62,-22.62],[2.75,2.75],color='white',linestyle='--',label='Standing eye Z2.75')
    ax.set(xlim=(-47.15,-46.65),ylim=(-23.1,-22.2),zlim=(.8,5.1),xlabel='Raw X / m',ylabel='Raw Y / m',zlabel='Raw Z / m',title='Actual source wall and vertical snow strip')
    ax.set_box_aspect((.5,.9,4.3));ax.view_init(elev=15,azim=-45);ax.legend(loc='upper left',fontsize=8)
    ax.set_xticks([]);ax.set_yticks([]);ax.set_xlabel('');ax.set_ylabel('')
    ax.set_zticks([1,2,2.75,4,5])
    ax.text2D(.08,.025,'Wall X = −47m; strip Y around −22.62m',transform=ax.transAxes,fontsize=9)
    b=fig.add_subplot(122)
    b.plot([-47,-47],[-22.8,-22.4],color='#B27C40',linewidth=3,label='Original wall3706 X−47')
    for i,line in enumerate(sections):b.plot(line[:,0],line[:,1],color='#00dfba',linewidth=2,label='Snow2831 eye-plane section' if i==0 else None)
    b.axvline(-47.2325195,color='#ed6c70',linestyle='--',label='Registered wall at this section')
    b.set(xlim=(-47.3,-46.85),ylim=(-22.8,-22.4),xlabel='Raw X / m',ylabel='Raw Y / m',title='Exact source section at standing eye Z2.75')
    b.set_aspect('equal');b.legend(fontsize=8,loc='upper left')
    fig.suptitle('Read-only source evidence. The 10cm-wide vertical strip overlaps the original wall plane.',fontsize=13)
    fig.savefig(out/'snow2831-wall3706-raw-source.png',dpi=150)
    plt.close(fig)
    result=dict(scope=__doc__,rawPackSha256=hashlib.sha256(pack.read_bytes()).hexdigest(),
                displayWarpSha256=hashlib.sha256(wpath.read_bytes()).hexdigest(),snowSourceFaces=len(snow),
                snowOriginalFaceRange=[1185315,1185680],rawBounds=np.array([sv.min(0),sv.max(0)]).tolist(),
                relativeZBounds=[float(relative.min()),float(relative.max())],
                sourceGroundBounds=[float(ground.min()),float(ground.max())],
                displayedBounds=np.array([displayed.reshape(-1,2).min(0),displayed.reshape(-1,2).max(0)]).tolist(),
                sourceEyePlaneSection=[x.tolist() for x in sections],
                proposal='Include only these proven wall-attached source faces in wall115 registration. Preserve all source Z and UV/alpha profiles. Keep the existing along-span bounds and all other snow objects unchanged. This is a proposal, not a geometry mutation.',
                limitation='The frozen control floor differs slightly from the nearest real floor; raw standing-eye rays still hit this strip. Known WindStreak support exclusion is recorded separately in center-notch-raw-space.json.')
    (out/'snow2831-wall-family-proposal.json').write_text(json.dumps(result,indent=2))
    print(json.dumps({k:result[k] for k in ['snowSourceFaces','rawBounds','relativeZBounds','displayedBounds']},indent=2))


if __name__=='__main__':run()

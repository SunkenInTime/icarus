"""Prove source-backed sewer sign, lights and recessed vent membership."""
import json
from pathlib import Path
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
from mpl_toolkits.mplot3d.art3d import Poly3DCollection
import numpy as np
import shapely
from declare_split_legacy105_connected_region import ROOT, REV, sha


def main():
    output=REV/'split-sewer108-attachment-review-v1'
    output.mkdir(exist_ok=False)
    path=ROOT/'supplemented-v2/world/split/geometry.npz'
    d=np.load(path)
    meta=json.loads(path.with_suffix('.json').read_text())
    def mesh(oid):
        o=meta['objects'][oid]
        ids=np.arange(o['firstFace'],o['firstFace']+o['faceCount'])
        return ids,d['points'][d['faces'][ids]].astype(float)
    ids,shell=mesh(6169)
    rows=[]
    fig=plt.figure(figsize=(15,11))
    all_tri,all_ids,all_owners=[],[],[]
    for i,(oid,axis,plane) in enumerate([(6143,0,66.00274658203125),(814,0,66.00274658203125),
                                       (815,0,66.00274658203125),(6249,1,40.00355529785156)]):
        faces,tri=mesh(oid)
        other=[a for a in range(3) if a!=axis]
        direct=(shell[:,:,axis]==plane).all(1)
        backing=direct.copy()
        if oid==6249:
            # The shell has an authored recess here: two backing triangles
            # and eight returns connect its floor to the surrounding wall.
            backing |= np.isin(ids,list(range(2037535,2037543))+[2037513,2037514])
        profile=shapely.union_all(shapely.polygons(tri[:,:,other]))
        direct_profile=shapely.union_all(shapely.polygons(shell[direct][:,:,other]))
        backing_profile=shapely.union_all(shapely.polygons(shell[backing][:,:,other]))
        area=float(shapely.difference(profile,backing_profile).area)
        assert area==0,(oid,area)
        for owner,fi,t in [(6169,ids[backing],shell[backing]),(oid,faces,tri)]:
            all_tri.extend(t);all_ids.extend(fi);all_owners.extend([owner]*len(fi))
        mids=d['material_indices'][faces]
        rows.append(dict(object=oid,path=meta['objects'][oid]['path'],rawSourceFaces=faces.tolist(),
            originalBoundsMeters=meta['objects'][oid]['boundsMeters'],backingObject=6169,
            backingRawSourceFaces=ids[backing].tolist(),backingAxis=axis,outerPlaneNativeMeters=plane,
            uncoveredProjectionAreaMetersSquared=area,
            projectionOutsideOuterPlaneOnlyMetersSquared=float(shapely.difference(profile,direct_profile).area),
            nativeNormalDepthRangeMeters=[float(tri[:,:,axis].min()-plane),float(tri[:,:,axis].max()-plane)],
            materials=[dict(material=int(mid),metadata=meta['materials'][int(mid)],
                rawSourceFaces=faces[mids==mid].tolist()) for mid in np.unique(mids)],
            recessBackPlaneMeters=39.96355438232422 if oid==6249 else None))
        ax=fig.add_subplot(2,2,i+1,projection='3d')
        minimum=tri.min((0,1));maximum=tri.max((0,1))
        near=(shell.max(1)>=minimum-.2).all(1)&(shell.min(1)<=maximum+.2).all(1)&backing
        ax.add_collection3d(Poly3DCollection(shell[near],facecolors='#8098ac',edgecolors='#688195',alpha=.25,linewidths=.25))
        ax.add_collection3d(Poly3DCollection(tri,facecolors='#e5ae44',edgecolors='#865c20',alpha=.85,linewidths=.25))
        low=minimum-.08;high=maximum+.08
        low[axis]=min(low[axis],plane-.06);high[axis]=max(high[axis],plane+.04)
        ax.set_xlim(low[0],high[0]);ax.set_ylim(low[1],high[1]);ax.set_zlim(low[2],high[2])
        spans=high-low;spans[axis]*=4
        ax.set_box_aspect(spans)
        ax.view_init(18,-25 if axis==0 else 70)
        ax.set_title(f'Object {oid}: full source against actual 6169 backing')
        ax.set_xlabel('Native X m');ax.set_ylabel('Native Y m');ax.set_zlabel('Original Z m')
    fig.suptitle('Original source attachments. Normal depth expanded four times; no geometry moved.\nThe sign keeps its masked material; lamps and recessed vent keep their finite geometry.')
    fig.tight_layout(rect=[0,0,1,.94]);fig.savefig(output/'source-attachments-four-views.png',dpi=160)
    np.savez_compressed(output/'original-attachments-and-backing.npz',rawSourceFaces=all_ids,
        sourceObjectIds=all_owners,originalTriangles=all_tri)
    report=dict(sourceGeometrySha256=sha(path),sourceMetadataSha256=sha(path.with_suffix('.json')),
        scriptSha256=sha(Path(__file__)),packetSha256=sha(output/'original-attachments-and-backing.npz'),
        attachments=rows,productionMutation=False,
        roleEvidence='Complete projected source attachments fit actual finite backing faces. The vent occupies a modeled recess, whose returns and back plane are explicitly included. No name-based material admission or geometry deletion.',
        excluded=[dict(object=627,reason='Freestanding low paint can; source location remains independent of wall mapping.'),
                  dict(object=7902,reason='Large lower box ends at Z 2.95268, below the entrance floor. Keep separate source height and floor semantics.')])
    (output/'report.json').write_text(json.dumps(report,indent=2)+'\n')
    print(json.dumps([dict(object=r['object'],faces=len(r['rawSourceFaces']),uncoveredArea=r['uncoveredProjectionAreaMetersSquared']) for r in rows]))


if __name__=='__main__':
    main()

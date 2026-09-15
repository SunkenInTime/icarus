"""Review the complete wall-bin mesh against its actual adjoining source wall.

This is a membership proposal for an unchanged field, not a packed candidate.
Mapped vertex bounds do not replace finite-cell or rendered contact verification.
"""
import json
from pathlib import Path

import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
from mpl_toolkits.mplot3d.art3d import Poly3DCollection
import numpy as np
import shapely

from lift_reviewed_wall_source_heights import sha
from tactical_alignment_composite import explicit_warp


def main():
    root=Path('E:/IcarusWorldAudit/2026-09-06')
    rev=root/'tactical-visibility-revision'
    output=rev/'split-wall-bin7852-attachment-proposal-v1'
    if output.exists():raise FileExistsError(output)
    geometry=root/'supplemented-v2/world/split/geometry.npz'
    metadata=root/'supplemented-v2/world/split/geometry.json'
    objects=json.loads(metadata.read_text())['objects']
    with np.load(geometry) as data:
        points,faces=data['points'],data['faces']
    def mesh(index):
        obj=objects[index]
        ids=np.arange(obj['firstFace'],obj['firstFace']+obj['faceCount'])
        return ids,points[faces[ids]]
    bin_ids,bin_mesh=mesh(7852)
    wall_ids,wall_mesh=mesh(7899)
    # Use the literal wall plane. Rounded native X36 is 1.18mm away.
    plane=float(points[faces[2853933]][0,0])
    selected=(wall_mesh[:,:,0]==plane).all(1)
    wall_ids,wall_mesh=wall_ids[selected],wall_mesh[selected]
    wall_profile=shapely.union_all(shapely.polygons(wall_mesh[:,:,1:]))
    bin_profile=shapely.union_all(shapely.polygons(bin_mesh[:,:,1:]))
    assert wall_profile.covers(bin_profile)
    crossing=(bin_mesh[:,:,0].min(1)<plane)&(bin_mesh[:,:,0].max(1)>plane)
    assert crossing.any()
    field_path=rev/'split-legacy105-connected-region-proposal-v6/region-declaration.json'
    family=json.loads(field_path.read_text())
    source=np.asarray(family['sourceVerticesSvg']);target=np.asarray(family['targetVerticesSvg'])
    field=explicit_warp(source,target-source,np.asarray(family['triangles']))
    projection_path=root/'tactical-alignment-sides-v1/split.json'
    projection=np.asarray(json.loads(projection_path.read_text())['nativeToAttackSvg'])
    svg=bin_mesh[:,:,:2]@projection[:,:2].T+projection[:,2]
    mapped=field.apply(svg.reshape(-1,2)).reshape(-1,3,2)
    assert mapped[:,:,0].max()<=279.074+1e-10
    output.mkdir()
    np.savez_compressed(output/'source-attachment.npz',binRawFaces=bin_ids,
        binTriangles=bin_mesh,wallRawFaces=wall_ids,wallTriangles=wall_mesh,
        binFacesCrossingLiteralWall=bin_ids[crossing],mappedBinVerticesSvg=mapped)
    fig=plt.figure(figsize=(12,6))
    for i,azimuth in enumerate([-65,115]):
        ax=fig.add_subplot(1,2,i+1,projection='3d')
        ax.add_collection3d(Poly3DCollection(wall_mesh,facecolors='#5a91bf',alpha=.25))
        ax.add_collection3d(Poly3DCollection(bin_mesh,facecolors='#c98c39',edgecolors='#79541f',linewidths=.15,alpha=.75))
        ax.set_xlim(35.45,36.10);ax.set_ylim(32.,34.)
        ax.set_zlim(3.5,5.25);ax.set_box_aspect([.65,2,1.75]);ax.view_init(22,azimuth)
        ax.set_xlabel('Native X m');ax.set_ylabel('Native Y m');ax.set_zlabel('Original Z m')
    fig.suptitle('Complete bin7852 intersects the literal wall7899 plane\nBlue: existing wall. Gold: original bin. No geometry moved in these source views.')
    fig.tight_layout(rect=[0,0,1,.88]);fig.savefig(output/'original-source-attachment.png',dpi=150);plt.close(fig)
    report=dict(scope=__doc__,sourceGeometrySha256=sha(geometry),sourceMetadataSha256=sha(metadata),
        existingFieldSha256=sha(field_path),projectionSha256=sha(projection_path),
        sourcePacketSha256=sha(output/'source-attachment.npz'),scriptSha256=sha(Path(__file__)),
        binObject=7852,binFaces=len(bin_ids),backingWallObject=7899,backingWallFaces=wall_ids.tolist(),
        literalWallNativeX=plane,maximumProtrusionMeters=float(bin_mesh[:,:,0].max()-plane),
        intersectingBinFaces=int(crossing.sum()),binProjectionEntirelyWithinOriginalWall=True,
        binOriginalHeightRangeMeters=[float(bin_mesh[:,:,2].min()),float(bin_mesh[:,:,2].max())],
        mappedVertexBoundsSvg=[mapped.min((0,1)).tolist(),mapped.max((0,1)).tolist()],
        proposedDecision='Add all904 original bin faces to existing200105 field as embedded wall detail absent from the SVG. Preserve every source height, UV and material decision. Change no field coordinates.',
        acceptance='Proposal only. Full cell clipping, source partition, exact first contacts and both-side rendered results remain required.')
    (output/'report.json').write_text(json.dumps(report,indent=2)+'\n')
    print(json.dumps(report,indent=2))


if __name__=='__main__':main()

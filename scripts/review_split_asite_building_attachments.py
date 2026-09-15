"""Geometric attachment witnesses for the finite A-site building proposal."""
import json
from pathlib import Path

import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
from mpl_toolkits.mplot3d.art3d import Poly3DCollection
import numpy as np

from declare_split_asite_return18_region import ROOT, REV, sha


def main():
    out=REV/'split-asite-building-connected-proposal-v6'
    path=out/'region-declaration.json';family=json.loads(path.read_text())
    report_path=out/'source-attachment-review.json';assert not report_path.exists()
    raw_path=ROOT/'supplemented-v2/world/split/geometry.npz';raw=np.load(raw_path);metadata=json.loads(raw_path.with_suffix('.json').read_text())
    meshes={};face_ids={}
    for oid in family['objects']+[5856,5893,5894]:
        ob=metadata['objects'][oid];ids=np.arange(ob['firstFace'],ob['firstFace']+ob['faceCount']);face_ids[oid]=ids
        meshes[oid]=raw['points'][raw['faces'][ids]].astype(float)
    pairs=[(i,5849) for i in range(438,446)]+[(372,5849),(5840,5849),
        (430,5857),(430,5849),(5841,5857),(449,5857),(5800,5856),
        *[(i,5857) for i in range(140,144)],(392,142),(392,143),(394,140),(394,141),
        (429,5857),(429,5853),(5853,5857),(447,5849),(447,5858)]
    records=[]
    for detail,parent in pairs:
        dt=meshes[detail];pt=meshes[parent];p0=pt[:,0];e1=pt[:,1]-p0;e2=pt[:,2]-p0
        witnesses=[]
        for index,tri in enumerate(dt):
            for edge in range(3):
                start=tri[edge];end=tri[(edge+1)%3];direction=end-start
                cross=np.cross(np.broadcast_to(direction,e2.shape),e2);det=np.einsum('ij,ij->i',e1,cross)
                keep=det!=0
                inv=np.zeros(len(det));inv[keep]=1/det[keep]
                offset=start-p0;u=np.einsum('ij,ij->i',offset,cross)*inv;q=np.cross(offset,e1)
                v=np.einsum('ij,j->i',q,direction)*inv;t=np.einsum('ij,ij->i',q,e2)*inv
                margin=np.minimum.reduce([u,v,1-u-v,t,1-t])
                # A witness well inside both the segment and triangle avoids
                # relying on a rounded edge-touch or a proximity threshold.
                selected=np.flatnonzero(keep&(margin>1e-6))
                for pi in selected:
                    point=start+t[pi]*direction;reconstructed=p0[pi]+u[pi]*e1[pi]+v[pi]*e2[pi]
                    witnesses.append(dict(detailOriginalFace=int(face_ids[detail][index]),detailEdge=edge,parentOriginalFace=int(face_ids[parent][pi]),
                        pointMeters=point.tolist(),segmentParameter=float(t[pi]),parentBarycentrics=[float(1-u[pi]-v[pi]),float(u[pi]),float(v[pi])],
                        minimumInteriorParameter=float(margin[pi]),reconstructionErrorMeters=float(np.linalg.norm(point-reconstructed))))
        records.append(dict(detailObject=detail,parentObject=parent,detailPath=metadata['objects'][detail]['path'],parentPath=metadata['objects'][parent]['path'],
            positiveInteriorIntersectionCount=len(witnesses),witnesses=witnesses,
            interpretation='Positive interior source-geometry intersection establishes attachment/overlap for this pair.' if witnesses else 'No positive-interior edge/triangle witness. Absence does not establish detachment; coplanar contacts and parent-edge crossings are not tested.'))
    full=np.load(REV/'full-height-input-v1/split/source-correspondence.npz')['sourceFaces'];retained=set(full.tolist())
    source_ids=np.array(family['reviewedSourceFaces']);omitted=np.array([i for i in source_ids if int(i) not in retained])
    materials=[]
    for mid in np.unique(raw['material_indices'][source_ids]):
        ids=source_ids[raw['material_indices'][source_ids]==mid]
        materials.append(dict(materialIndex=int(mid),sourceFaceCount=len(ids),retainedFaceCount=sum(int(i) in retained for i in ids),material=metadata['materials'][int(mid)]))
    fig=plt.figure(figsize=(18,9))
    groups=[([5849,*range(438,442)],[-45,22]),([5849,5858,*range(442,446)],[-125,25]),([5857,430,5849],[-55,22]),([5857,5800,5856],[145,20])]
    for plot,(objects,view) in enumerate(groups):
        ax=fig.add_subplot(2,2,plot+1,projection='3d')
        for oid in objects:
            color='#559dbe' if oid in [5849,5857] else '#dc9a39' if oid in [5856,5800] else '#63b683'
            ax.add_collection3d(Poly3DCollection(meshes[oid],facecolors=color,edgecolors=color,alpha=.10 if oid in [5849,5857,5856] else .65,linewidths=.12))
        if plot==0:ax.set_xlim(66,72);ax.set_ylim(80,82);ax.set_zlim(3.1,7.5);ax.set_box_aspect([6,2,4.4])
        elif plot==1:ax.set_xlim(75,78);ax.set_ylim(76,82);ax.set_zlim(3.1,7.5);ax.set_box_aspect([3,6,4.4])
        elif plot==2:ax.set_xlim(59,66);ax.set_ylim(82,84.5);ax.set_zlim(1.5,7.5);ax.set_box_aspect([7,2.5,6])
        else:ax.set_xlim(66,70);ax.set_ylim(83,92);ax.set_zlim(6.5,9.5);ax.set_box_aspect([4,9,3])
        ax.view_init(view[1],view[0]);ax.set_xlabel('Native X m');ax.set_ylabel('Native Y m');ax.set_zlabel('Original Z m')
        ax.set_title(['Window stack on23','Window stack and ticket shell on24','Full doorway430, both jambs retained','Finite upper beam and independent pitched roof'][plot])
    fig.suptitle('Unmodified full source meshes. Axes crop context; source instances are not cut or filled.\nPositive interior edge/triangle intersections are stored as attachment witnesses; names alone do not establish the relation.')
    fig.tight_layout(rect=[0,0,1,.94]);fig.savefig(out/'source-attachment-context-3d.png',dpi=150);plt.close(fig)
    report=dict(declarationSha256=sha(path),scriptSha256=sha(Path(__file__)),sourceGeometrySha256=sha(raw_path),productionMutation=False,
        attachmentPairs=records,sourceFaceCount=len(source_ids),retainedFaceCount=len(source_ids)-len(omitted),
        omittedOriginalFaceIds=omitted.tolist(),materialInventory=materials,
        sourceHeightGap=dict(interiorMaximumZ=float(meshes[5857][:,:,2].max()),beamMinimumZ=float(meshes[5800][:,:,2].min()),
            gapMeters=float(meshes[5800][:,:,2].min()-meshes[5857][:,:,2].max()),meaning='An existing gap between these two instances, not a claim of a globally clear sightline; the independent roof and backing still exist.'),
        limits=['Witnesses prove source geometry intersection only. They do not alone approve collapsing a whole instance onto an SVG wall.',
                'All full source faces and current material omissions remain attributable. Candidate partition and source-Z/UV checks have not run.',
                'The complete doorway profile remains finite; its full X bounds are not used as right-jamb thickness.'])
    report_path.write_text(json.dumps(report,indent=2)+'\n')
    print(json.dumps(dict(pairs=len(records),positivePairs=sum(bool(r['positiveInteriorIntersectionCount']) for r in records),noInteriorWitness=[(r['detailObject'],r['parentObject']) for r in records if not r['positiveInteriorIntersectionCount']],sourceFaces=len(source_ids),retainedFaces=len(source_ids)-len(omitted))))


if __name__=='__main__':main()

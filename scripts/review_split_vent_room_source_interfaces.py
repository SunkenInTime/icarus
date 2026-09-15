"""Read-only original-height vent room interfaces for the 173/174 proposal."""
import json
from pathlib import Path

import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
from matplotlib.collections import LineCollection
from mpl_toolkits.mplot3d.art3d import Poly3DCollection
import numpy as np
import shapely

from render_split_remaining_corner_families import sections
from render_competing_floor_assemblies import clip_mesh_xy
from tactical_alignment_audit import vector_lines
from lift_reviewed_wall_source_heights import sha

ROOT = Path('E:/IcarusWorldAudit/2026-09-06')
REV = ROOT/'tactical-visibility-revision'


def main():
    out = REV/'split-vent-room-source-interfaces-v2'
    out.mkdir(exist_ok=True)
    if any(out.iterdir()): raise FileExistsError(out)
    raw_path = ROOT/'supplemented-v2/world/split/geometry.npz'
    data = np.load(raw_path)
    points, faces = data['points'], data['faces']
    metadata = json.loads(raw_path.with_suffix('.json').read_text())
    projection = ROOT/'tactical-alignment-sides-v1/split.json'
    affine = np.array(json.loads(projection.read_text())['nativeToAttackSvg'])
    bounds = [208., 166., 302., 214.]
    main_objects = [7795, 7796, 4773, 7797, 7791, 7792]
    colors = {7795:'#dc2626', 7796:'#2563eb', 4773:'#a21caf',
              7797:'#059669', 7791:'#d97706', 7792:'#0891b2'}
    triangles = {}
    face_ids = {}
    inventory = []
    for index, obj in enumerate(metadata['objects']):
        bb = np.array(obj['boundsMeters'])
        projected = bb[:,:2]@affine[:,:2].T + affine[:,2]
        if not ((projected.max(0) >= bounds[:2]).all() and
                (projected.min(0) <= bounds[2:]).all()):
            continue
        ids = np.arange(obj['firstFace'], obj['firstFace']+obj['faceCount'])
        tri = points[faces[ids]].copy()
        tri[:,:,:2] = tri[:,:,:2]@affine[:,:2].T + affine[:,2]
        selected = ((tri[:,:,:2].max(1) >= bounds[:2]).all(1) &
                    (tri[:,:,:2].min(1) <= bounds[2:]).all(1))
        if not selected.any(): continue
        inventory.append(dict(object=index, path=obj['path'], faces=ids[selected].tolist(),
                              originalObjectFaces=obj['faceCount']))
        if index in main_objects:
            triangles[index] = tri
            face_ids[index] = ids
    lines = vector_lines(Path('assets/maps/split_map.svg'))
    heights = [2.65, 4.35, 6.5, 8.25, 12.75, 15.75]
    records = []
    ranges = [('whole-room',bounds), ('173-and-lower-doorway',[253.,166.,286.,213.]),
              ('175-and-176-interface',[249.,180.,258.,199.])]
    for name, box in ranges:
        fig, axes = plt.subplots(2,3,figsize=(18,11))
        for ax, z in zip(axes.flat, heights):
            for edge, line in enumerate(lines):
                if (line.max(0)>=box[:2]).all() and (line.min(0)<=box[2:]).all():
                    ax.plot(*line.T,color='#111827',lw=2.5)
                    ax.text(*line.mean(0),str(edge),fontsize=7,clip_on=True)
            for obj in main_objects:
                seg, rows = sections(triangles[obj],z)
                ax.add_collection(LineCollection(seg,colors=colors[obj],lw=1.15,label=str(obj)))
                if name == 'whole-room':
                    records.append(dict(object=obj,z=z,rawFaces=face_ids[obj][rows].tolist(),
                                        segmentsSourceSvg=seg.tolist()))
            ax.set(xlim=(box[0],box[2]),ylim=(box[3],box[1]));ax.set_aspect('equal')
            ax.grid(alpha=.18);ax.set_title(f'Absolute source Z {z:.2f} m')
            ax.legend(fontsize=7,loc='lower left')
        fig.suptitle('Original source sections before display W. Black is unchanged SVG artwork.\n'
                     'Red 7795 tube, blue 7796 lower room; green/orange/cyan are existing mapped upper room neighbors. '
                     'No material or blocker roles inferred from these lines.',fontsize=11)
        fig.tight_layout(rect=[0,0,1,.95]);fig.savefig(out/f'{name}-six-heights.png',dpi=145);plt.close(fig)
    fig=plt.figure(figsize=(17,9))
    box=[253.,166.,286.,213.]
    for number, az in enumerate([-65,115],1):
        ax=fig.add_subplot(1,2,number,projection='3d')
        for obj in main_objects:
            tri=clip_mesh_xy(triangles[obj],np.array(box[:2]),np.array(box[2:]))
            if len(tri):ax.add_collection3d(Poly3DCollection(tri,facecolors=colors[obj],edgecolors=colors[obj],lw=.2,alpha=.25))
        ax.set(xlim=(box[0],box[2]),ylim=(box[1],box[3]),zlim=(0,18),xlabel='Source SVG X',ylabel='Source SVG Y',zlabel='Original Z, m')
        ax.set_box_aspect([33,47,18*3.91]);ax.view_init(20,az)
    fig.suptitle('Original 7796 room and connected tube/upper room. Heights are unchanged.',fontsize=13)
    fig.tight_layout();fig.savefig(out/'original-room-two-views.png',dpi=145);plt.close(fig)
    pairs=[]
    for first,second in [(7795,7796),(7795,7797),(7795,7791),(7795,7792),(7796,7792)]:
        a=np.unique(triangles[first].reshape(-1,3),axis=0)
        b=np.unique(triangles[second].reshape(-1,3),axis=0)
        literal=set(map(tuple,a))&set(map(tuple,b))
        row=dict(first=first,second=second,literalSharedSourceVertices=len(literal),sections=[])
        for z in heights:
            aa,_=sections(triangles[first],z);bb,_=sections(triangles[second],z)
            if not len(aa) or not len(bb):
                row['sections'].append(dict(z=z,bothPresent=False));continue
            ga=shapely.union_all(shapely.linestrings(aa));gb=shapely.union_all(shapely.linestrings(bb))
            inter=shapely.intersection(ga,gb)
            row['sections'].append(dict(z=z,bothPresent=True,minimumDistanceSvg=float(ga.distance(gb)),
                intersectionLengthSvg=float(inter.length),intersectionCoordinates=shapely.get_coordinates(inter).tolist()))
        pairs.append(row)
    report=dict(scope=__doc__,sourceGeometrySha256=sha(raw_path),sourceMetadataSha256=sha(raw_path.with_suffix('.json')),
        projectionSha256=sha(projection),scriptSha256=sha(Path(__file__)),
        objects=[dict(index=obj,**metadata['objects'][obj]) for obj in main_objects],
        nearbyObjectCount=len(inventory),interfaces=pairs,
        existingV30BindingSha256=sha(REV/'split-wall-family-normalized-candidate-v30-cached-v1/bindings.json'),
        keyConstraints=['Source 7797 and existing 175/176 upper room begin around absolute Z 6.5 m. They cannot establish lower standing joins by themselves.',
            'Do not stretch the top wall ending around source X281 to the full SVG 172 endpoint at X298.744.',
            'The lower 174 opening and higher horizontal header are separate original-height profiles.',
            'An independent room field must meet the existing V30 200190 field and 175/176 fields only where the actual source interfaces meet.'],
        productionMutation=False,fieldDeclared=False,
        limits='Original geometry diagnostic only. Section intersections are source attachment evidence, not proof of watertightness or material opacity. No candidate or gameplay accuracy claim.')
    (out/'source-interfaces.json').write_text(json.dumps(report,indent=2)+'\n')
    (out/'source-sections.json').write_text(json.dumps(records,indent=2)+'\n')
    (out/'unfiltered-neighbor-inventory.json').write_text(json.dumps(inventory,indent=2)+'\n')
    print(json.dumps(dict(output=str(out),nearbyObjects=len(inventory),pairs=[dict(first=p['first'],second=p['second'],literalSharedVertices=p['literalSharedSourceVertices']) for p in pairs])))


if __name__=='__main__':main()

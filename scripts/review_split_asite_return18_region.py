"""Continuous source-contact checks and actual-artwork source overlays for18."""
import gzip
import io
import json
from pathlib import Path

import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
from matplotlib.collections import LineCollection
from mpl_toolkits.mplot3d.art3d import Poly3DCollection
import numpy as np
from PIL import Image, ImageDraw
import resvg_py
import shapely

from authored_region_cells import barycentric
from declare_split_asite_return18_region import ROOT, REV, sha
from render_split_remaining_corner_families import sections
from tactical_alignment_composite import explicit_warp
from verify_region_contact import segment_cells
from verify_region_mapping import verify_rank_one_declarations
from verify_split_legacy105_declared_contacts import interval_values, wall_gate


def main():
    out = REV/'split-asite-return18-connected-proposal-v2'
    declaration_path = out/'region-declaration.json'
    report_path = out/'continuous-source-review.json'
    assert not report_path.exists()
    family = json.loads(declaration_path.read_text())
    s = np.array(family['sourceVerticesSvg'])
    t = np.array(family['targetVerticesSvg'])
    c = np.array(family['triangles'])
    rank = verify_rank_one_declarations(family)
    field = explicit_warp(s, t-s, c)
    polygons = shapely.polygons(s[c])
    tree = shapely.STRtree(polygons)
    raw_path = ROOT/'supplemented-v2/world/split/geometry.npz'
    raw = np.load(raw_path)
    metadata = json.loads(raw_path.with_suffix('.json').read_text())
    warp_path = REV/'display-warps-v1/split.display-warp.json.gz'
    w = json.loads(gzip.decompress(warp_path.read_bytes()))
    matrix = np.column_stack((w['projection']['axisU'], w['projection']['axisV']))
    origin = np.array(w['projection']['origin'])
    ws = np.array(w['sourceNativeMeters']).reshape(-1, 2)@matrix.T+origin
    wt = np.array(w['targetAttackSvg']).reshape(-1, 2)
    wc = np.array(w['triangles']).reshape(-1, 3)
    forward = explicit_warp(ws, wt-ws, wc)
    old = json.loads((REV/'split-wall-family-normalized-candidate-v30-cached-v1/bindings.json').read_text())
    old17 = next(f for f in old['families'] if f['edge'] == 17)
    along17 = lambda x: old17['targetAlong'][0]+(x-old17['sourceAlong'][0])/np.diff(old17['sourceAlong'])[0]*np.diff(old17['targetAlong'])[0]
    contract = family['original17AlongContract']
    top_y = 58.07386812970583
    low_y = 58.176256
    bottom_y = next(r['sourceCoordinate'] for r in family['sourceConstraints'] if r['axis'] == 1 and abs(r['sourceCoordinate']-85.343464)<1e-5)
    bottom_standing = next(r['sourceCoordinate'] for r in family['sourceConstraints'] if r['axis'] == 1 and abs(r['sourceCoordinate']-85.441210)<1e-5)
    lower_x = next(r['sourceCoordinate'] for r in family['sourceConstraints'] if r['axis'] == 0 and abs(r['sourceCoordinate']-388.028614)<1e-5)
    contact_specs = [
        ('upper top17', [[contract['unchangedSourceInterval'][0], top_y], [contract['upperReturnSourceX'], top_y]], [[315.225,56.809],[409.855,56.809]]),
        ('low top17', [[contract['unchangedSourceInterval'][0], low_y], [contract['lowPlinthSourceX'],low_y]], [[315.225,56.809],[409.855,56.809]]),
        ('standing return18', [[contract['upperReturnSourceX'],top_y],[contract['upperReturnSourceX'],bottom_standing]], [[409.855,56.809],[409.855,84.9854]]),
        ('low plinth18', [[contract['lowPlinthSourceX'],low_y],[contract['lowPlinthSourceX'],bottom_y]], [[409.855,56.809],[409.855,84.9854]]),
        ('lower standing19', [[lower_x,bottom_standing],[contract['upperReturnSourceX'],bottom_standing]], [[388.058,84.9854],[409.855,84.9854]]),
        ('lower plinth19', [[lower_x,bottom_y],[contract['lowPlinthSourceX'],bottom_y]], [[388.058,84.9854],[409.855,84.9854]]),
    ]
    contacts = [dict(name=name, **wall_gate(family, segment, authored)) for name, segment, authored in contact_specs]
    a,b = contract['unchangedSourceInterval']
    data = segment_cells(family, [[a,top_y],[b,top_y]])
    old_error = 0.
    for lo,hi in zip(data[-1][:-1],data[-1][1:]):
        p, values = interval_values(data,lo,hi,rank)
        expected = np.column_stack((along17(p[[0,2],0]),np.full(2,56.809)))
        old_error = max(old_error, float(np.linalg.norm(values-expected,axis=2).max()))
    assert old_error < 1e-10
    a,b = contract['adjustedCornerSourceInterval']
    data = segment_cells(family, [[a,top_y],[b,top_y]])
    along_change = 0.
    for lo,hi in zip(data[-1][:-1],data[-1][1:]):
        p, values = interval_values(data,lo,hi,rank)
        along_change = max(along_change,float(abs(values[:,:,0]-along17(p[[0,2],0])).max()))

    lo = np.array([67.5,83.,1.5]); hi=np.array([70.,92.,11.])
    inventory = []
    meshes = {}
    native_meshes = {}
    retained = set(np.load(REV/'full-height-input-v1/split/source-correspondence.npz')['sourceFaces'].tolist())
    for oid, obj in enumerate(metadata['objects']):
        lower,upper=np.array(obj['boundsMeters'])
        if np.any(upper<lo) or np.any(lower>hi):
            continue
        ids=np.arange(obj['firstFace'],obj['firstFace']+obj['faceCount'])
        native=raw['points'][raw['faces'][ids]].astype(float)
        overlapping=np.all(native.max(1)>=lo,axis=1)&np.all(native.min(1)<=hi,axis=1)
        if not overlapping.any():
            continue
        display=native.copy();display[:,:,:2]=display[:,:,:2]@matrix.T+origin
        meshes[oid]=display;native_meshes[oid]=native
        inventory.append(dict(object=oid,path=obj['path'],originalFaceIds=ids.tolist(),
            triangleAabbOverlapOriginalFaces=ids[overlapping].tolist(),
            proposedMember=oid in family['objects'],
            originalBoundsMeters=obj['boundsMeters'],retainedOriginalFaceCount=sum(int(i) in retained for i in ids)))
    selected_ids=np.array(family['reviewedSourceFaces'])
    np.savez_compressed(out/'reviewed-original-sources.npz',originalFaceIds=selected_ids,
        originalTriangles=raw['points'][raw['faces'][selected_ids]],originalUvs=raw['uvs'][raw['faces'][selected_ids]] if raw['uvs'].ndim==2 and len(raw['uvs'])==len(raw['points']) else raw['uvs'][selected_ids],
        materialIndices=raw['material_indices'][selected_ids])

    def mapped_segments(segments):
        output=[]
        for segment in segments:
            if np.linalg.norm(segment[1]-segment[0]) == 0:
                continue
            line=shapely.LineString(segment)
            for cell in tree.query(line,predicate='intersects'):
                for part in shapely.get_parts(shapely.intersection(line,polygons[cell])):
                    if not isinstance(part,shapely.LineString) or part.length==0:
                        continue
                    p=np.array(part.coords)[[0,-1]]
                    weights=barycentric(p,s[c[cell]])
                    if int(cell) in rank:
                        r=rank[int(cell)];a,b=r['endpoints'];q=a+(weights@r['parameters'])[:,None]*(b-a)
                    else:
                        q=weights@t[c[cell]]
                    output.append(q)
        return output

    # Original source-height sections with material policy explicitly visible.
    heights=[2.1,3.75,3.85,5.5,7.05,7.5,8.9]
    caches={}
    for z in heights:
        caches[z]={}
        for oid,tris in meshes.items():
            lines,idx=sections(tris,z)
            obj=metadata['objects'][oid]
            keep=np.array([int(obj['firstFace']+i) in retained for i in idx])
            lines=lines[keep.astype(bool)]
            if len(lines)==0:
                continue
            original=[forward.apply(line) for line in lines]
            proposal=mapped_segments(lines) if oid in family['objects'] else original
            caches[z][oid]=(original,proposal)
    fig, axes=plt.subplots(2,4,figsize=(20,10))
    for ax,z in zip(axes.flat,heights):
        for oid,(before,after) in caches[z].items():
            ax.add_collection(LineCollection(before,colors='#999999',linewidths=.7,alpha=.5))
            ax.add_collection(LineCollection(after,colors='#197dc2' if oid in family['objects'] else '#d87e20',linewidths=1.1))
        ax.plot([390,409.855,409.855,388.058],[56.809,56.809,84.9854,84.9854],color='#b32837',ls='--',lw=1.2)
        ax.set_xlim(388,414);ax.set_ylim(89,53);ax.set_aspect('equal');ax.set_title(f'Original absolute Z {z:g} m');ax.grid(alpha=.2)
    axes.flat[-1].axis('off')
    axes.flat[-1].text(0,1,'Blue: mapped proposed wall members\nOrange: unchanged retained source geometry\nGray: original source positions through W\nRed: authored wall contacts\n\nNo source height is extruded.\nSections do not sample alpha masks.\nThese are source overlays, not cone captures.\nPitched roof remains an independent blocker.',va='top',fontsize=12)
    fig.tight_layout();fig.savefig(out/'seven-original-height-sections.png',dpi=140);plt.close(fig)
    reflection=np.array(w['attackToDefenseSvg']['origin'])
    focuses={'top-joint':[[400,53],[414,63]],'mounted-return':[[400,61],[414,82]],'lower-joint':[[385,81],[414,90]]}
    for side in ['attack','defense']:
        svg=Path('assets/maps/split_map'+('_defense' if side=='defense' else '')+'.svg')
        base=Image.open(io.BytesIO(resvg_py.svg_to_bytes(svg_string=svg.read_text(),zoom=8,background='#101014'))).convert('RGB')
        convert=lambda p: reflection-np.array(p) if side=='defense' else np.array(p)
        for name,bounds in focuses.items():
            bb=convert(bounds);lower=np.floor(bb.min(0)*8).astype(int);upper=np.ceil(bb.max(0)*8).astype(int)
            for kind,index in [('source',0),('proposal',1)]:
                crop=base.crop(tuple(np.r_[lower,upper]));draw=ImageDraw.Draw(crop)
                for oid, pair in caches[3.75].items():
                    for line in pair[index]:
                        xy=convert(line)*8-lower
                        draw.line([tuple(p) for p in xy],fill='#65c7ff' if oid in family['objects'] else '#e39441',width=1)
                crop.save(out/f'{side}-{name}-{kind}-native8x.png')
    fig=plt.figure(figsize=(16,8))
    for k,az in enumerate([-45,140]):
        ax=fig.add_subplot(1,2,k+1,projection='3d')
        for oid in [5857,5873,140,141,142,143,392,394,5841,449,5800,5856]:
            if oid not in native_meshes:continue
            color='#3f9aca' if oid==5857 else '#d89130' if oid in [5856,5800] else '#70b080'
            ax.add_collection3d(Poly3DCollection(native_meshes[oid],facecolors=color,alpha=.2 if oid in [5857,5856] else .55,edgecolors=color,linewidths=.15))
        ax.set_xlim(66,71);ax.set_ylim(83,92);ax.set_zlim(1.5,10);ax.set_box_aspect([5,9,8.5]);ax.view_init(22,az)
        ax.set_xlabel('Native X m');ax.set_ylabel('Native Y m');ax.set_zlabel('Original Z m')
    fig.suptitle('Unmodified complete source instances. Blue interior wall, green mounted details and backing, orange upper beam / independent pitched roof.\nThe source shapes and height gaps are retained. Object names are not used as proof of attachment.')
    fig.tight_layout(rect=[0,0,1,.93]);fig.savefig(out/'original-return-members-and-roof-3d.png',dpi=150);plt.close(fig)
    report=dict(declarationSha256=sha(declaration_path),scriptSha256=sha(Path(__file__)),sourceGeometrySha256=sha(raw_path),
        productionMutation=False,contacts=contacts,unchangedOld17Along=dict(sourceInterval=contract['unchangedSourceInterval'],maximumErrorSvg=old_error),
        adjustedOld17Along=dict(sourceInterval=contract['adjustedCornerSourceInterval'],maximumChangeSvg=along_change,
            reason='The finite plinth and upper beam have different near depths. The connected corner maps their common wall normal to the authored joint while retaining their original Z and separate gaps.'),
        unfilteredLocalInventory=inventory,proposedObjects=family['objects'],
        sourceFaceCount=len(selected_ids),retainedFaceCount=sum(int(i) in retained for i in selected_ids),
        retainedMaterialIds=np.unique(raw['material_indices'][selected_ids]).tolist(),
        limits=['These continuous planar contact proofs and original-height source overlays do not establish gameplay or renderer correctness.',
                'No source face has been baked, deleted, extruded, or assigned a new Z/UV here.',
                'The independent pitched roof stays unchanged; above-wall rays may still hit that source geometry.',
                'Full original-height ray checks, actual candidate source partition, and both-side cone captures remain required.'])
    report_path.write_text(json.dumps(report,indent=2)+'\n')
    print(json.dumps(dict(contacts=len(contacts),normalError=max(r['maximumNormalErrorSvg'] for r in contacts),old17Error=old_error,cornerAlongChange=along_change,faces=len(selected_ids),inventory=len(inventory))))


if __name__=='__main__':
    main()

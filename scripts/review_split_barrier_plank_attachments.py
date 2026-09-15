"""Bounded whole-plank ownership proposal, no candidate or production bake."""
import copy
import gzip
import hashlib
import json
import xml.etree.ElementTree as ET
from pathlib import Path

import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
from matplotlib.collections import LineCollection
from mpl_toolkits.mplot3d.art3d import Poly3DCollection
import numpy as np
import shapely
from svgpathtools import parse_path

from build_split_normalized_wall_families import cut
from finite_region_cells import region_fragments
from region_partition_certificate import SourceCellCertificate
from render_split_remaining_corner_families import sections
from tactical_alignment_composite import explicit_warp

ROOT = Path('E:/IcarusWorldAudit/2026-09-06')
REV = ROOT/'tactical-visibility-revision'


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    out = REV/'split-barrier-planks-source-proposal-v1'
    out.mkdir(exist_ok=False)
    raw_path = ROOT/'supplemented-v2/world/split/geometry.npz'
    metadata_path = raw_path.with_suffix('.json')
    metadata = json.loads(metadata_path.read_text())
    raw = np.load(raw_path)
    binding_path = REV/'split-wall-family-normalized-candidate-v29/bindings.json'
    original = next(f for f in json.loads(binding_path.read_text())['families'] if f['edge']==200123)
    family = copy.deepcopy(original)
    new_ids = []
    for index in [501,502]:
        obj = metadata['objects'][index]
        new_ids.extend(range(obj['firstFace'],obj['firstFace']+obj['faceCount']))
    assert not set(new_ids)&set(family['reviewedSourceFaces'])
    family['reviewedSourceFaces'] = sorted(family['reviewedSourceFaces']+new_ids)
    family['objects'] = sorted(set(family['objects']+[501,502]))
    family['status'] = 'Whole-plank ownership proposal. Root source review required before any bake.'
    family['proposedAttachedPlanks'] = dict(objects=[501,502],rawSourceFaces=new_ids,
        policy='Same finite connected barrier field, original Z/UV and separate plank silhouettes retained. No face deletion or height infill.')
    family['unresolved'] = [x for x in family['unresolved'] if '4381/501' not in x]
    family['unresolved'].append('Standalone4381 remains separate. Planks501/502 are proposed ownership only pending source review.')
    (out/'region-declaration.json').write_text(json.dumps(family,indent=2))
    warp_path = REV/'display-warps-v1/split.display-warp.json.gz'
    w = json.loads(gzip.decompress(warp_path.read_bytes()))
    matrix = np.column_stack((w['projection']['axisU'],w['projection']['axisV']))
    origin = np.asarray(w['projection']['origin'])
    s = np.asarray(w['sourceNativeMeters']).reshape(-1,2)@matrix.T+origin
    t = np.asarray(w['targetAttackSvg']).reshape(-1,2)
    backward = explicit_warp(t,s-t,np.asarray(w['triangles']).reshape(-1,3))
    certifier = SourceCellCertificate(family)
    selected_objects = [501,502,597,598,600,4586,6166]
    colors = {501:'#e11d48',502:'#f97316',597:'#0891b2',598:'#2563eb',600:'#7c3aed',4586:'#64748b',6166:'#a16207'}
    box = [332.,260.,340.2,266.]
    originals,proposed,provenance,object_rows = {},{},[],[]
    for index in selected_objects:
        obj = metadata['objects'][index]
        ids = np.arange(obj['firstFace'],obj['firstFace']+obj['faceCount'])
        mesh = raw['points'][raw['faces'][ids]].astype(float)
        display = mesh.copy()
        display[:,:,:2] = display[:,:,:2]@matrix.T+origin
        originals[index] = display
        transformed = []
        for fid,native,svg in zip(ids,mesh,display):
            if (svg[:,:2].max(0)<box[:2]).any() or (svg[:,:2].min(0)>box[2:]).any():
                continue
            inside,_ = cut(list(np.column_stack((svg,np.eye(3)))),box)
            if len(inside)<3:
                continue
            for fragment,wcell,rcell in region_fragments(np.asarray(inside),family,backward,
                    containment_certificate=certifier.callback(native,matrix,origin,int(fid))):
                for j in range(1,len(fragment)-1):
                    triangle = fragment[[0,j,j+1]]
                    transformed.append(triangle[:,:3])
                    provenance.append((int(fid),index,rcell,wcell,triangle[:,3:6]))
        proposed[index] = np.asarray(transformed).reshape(-1,3,3)
        object_rows.append(dict(index=index,metadata=obj,svgBounds=[display[:,:,:2].min((0,1)).tolist(),display[:,:,:2].max((0,1)).tolist()],
                                proposedFragments=len(transformed)))
    svg_path = Path('assets/maps/split_map.svg')
    nearby = []
    for path_index,element in enumerate(ET.parse(svg_path).getroot().iter()):
        if not element.tag.endswith('path'):
            continue
        for segment_index,segment in enumerate(parse_path(element.get('d'))):
            sample = np.array([[segment.point(u).real,segment.point(u).imag] for u in np.linspace(0,1,17)])
            if not shapely.LineString(sample).intersects(shapely.box(*box)):
                continue
            nearby.append(dict(pathIndex=path_index,segmentIndex=segment_index,type=type(segment).__name__,
                               attributes={k:v for k,v in element.attrib.items() if k!='d'},points=sample.tolist()))
    def decorate(ax):
        for segment in nearby:
            ax.plot(*np.asarray(segment['points']).T,color='#111827',lw=2)
        ax.set_xlim(box[0],box[2]);ax.set_ylim(box[3],box[1]);ax.set_aspect('equal');ax.grid(alpha=.15)
    heights = [5.65,6.25,6.75,7.26902836134317,7.70,8.25]
    height_rows = []
    fig,axes = plt.subplots(3,2,figsize=(13,14))
    for ax,z in zip(axes.flat,heights):
        decorate(ax)
        segments_by_object = {}
        for index in selected_objects:
            lines,ids = sections(originals[index],z)
            segments_by_object[index] = shapely.union_all(shapely.linestrings(lines)) if len(lines) else shapely.GeometryCollection()
            ax.add_collection(LineCollection(lines,colors=colors[index],lw=2 if index in [501,502] else .9,label=f'{index} source'))
            if index in [501,502]:
                mapped,_ = sections(proposed[index],z)
                ax.add_collection(LineCollection(mapped,colors='#16a34a',lw=2.5,label=f'{index} proposed'))
        distances = []
        for plank in [501,502]:
            for backing in [597,598,600,4586,6166]:
                a,b = segments_by_object[plank],segments_by_object[backing]
                if a.is_empty or b.is_empty:
                    continue
                distances.append(dict(plank=plank,backing=backing,distanceSvg=float(a.distance(b)),
                                      intersects=bool(a.intersects(b))))
        height_rows.append(dict(absoluteZMeters=z,sectionDistances=distances))
        ax.set_title(f'Original absolute Z {z:.3f} m')
        if z==heights[0]:ax.legend(fontsize=7,ncol=2)
    fig.suptitle('Planks501/502 at the barrier corner. Black is every nearby authored SVG path.\nColored lines are original source sections; green is proposed complete plank mapping.',fontsize=12)
    fig.tight_layout(rect=[0,0,1,.95]);fig.savefig(out/'planks-original-height-sections.png',dpi=170);plt.close(fig)
    fig = plt.figure(figsize=(15,7))
    for column,state in enumerate(['source','proposed']):
        ax = fig.add_subplot(1,2,column+1,projection='3d')
        for index in selected_objects:
            mesh = originals[index] if state=='source' else proposed[index]
            choose = (mesh[:,:,:2].max(1)>=box[:2]).all(1)&(mesh[:,:,:2].min(1)<=box[2:]).all(1)&(mesh[:,:,2].min(1)<=8.6)&(mesh[:,:,2].max(1)>=5.4)
            ax.add_collection3d(Poly3DCollection(mesh[choose],facecolor=colors[index],edgecolor=colors[index],alpha=.8 if index in [501,502] else .16,linewidth=.3))
        ax.set_xlim(box[0],box[2]);ax.set_ylim(box[3],box[1]);ax.set_zlim(5.4,8.6);ax.set_box_aspect([8.2,6,8])
        ax.view_init(elev=20,azim=-66);ax.set_xlabel('Attack SVG X');ax.set_ylabel('Attack SVG Y');ax.set_zlabel('Original Z, m')
        ax.set_title('Original full source' if state=='source' else 'Proposed shared-field mapping, original heights')
    fig.tight_layout();fig.savefig(out/'planks-source-and-proposed-3d.png',dpi=180);plt.close(fig)
    np.savez_compressed(out/'source-and-proposed.npz',
        **{f'object{k}SourceTriangles':v for k,v in originals.items()},
        **{f'object{k}ProposedTriangles':v for k,v in proposed.items()},
        generatedRawFaces=np.array([r[0] for r in provenance]),generatedObjectIds=np.array([r[1] for r in provenance]),
        generatedRegionCells=np.array([r[2] for r in provenance]),generatedWarpCells=np.array([r[3] for r in provenance]),
        originalBarycentrics=np.array([r[4] for r in provenance]))
    report = dict(scope=__doc__,rawGeometrySha256=sha(raw_path),metadataSha256=sha(metadata_path),
        baselineBindingsSha256=sha(binding_path),displayWarpSha256=sha(warp_path),svgSha256=sha(svg_path),
        scriptSha256=sha(Path(__file__)),proposalSha256=sha(out/'region-declaration.json'),
        dataSha256=sha(out/'source-and-proposed.npz'),objects=object_rows,nearbySvgPaths=nearby,heightSections=height_rows,
        newRawSourceFaces=new_ids,existingMappingArraysUnchanged=all(family[k]==original[k] for k in ['sourceVerticesSvg','targetVerticesSvg','triangles','box']),
        acceptance='Proposal only. Original height profiles retained; root source review and independent source/pixel gates required before any candidate promotion.')
    (out/'review.json').write_text(json.dumps(report,indent=2))
    print(out,flush=True)


if __name__=='__main__':
    main()

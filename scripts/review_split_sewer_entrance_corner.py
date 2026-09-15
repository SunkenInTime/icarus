"""Review the complete source shells around Split SVG walls108 through111."""
import argparse
import gzip
import json
from pathlib import Path
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
from matplotlib.collections import LineCollection
import numpy as np
import shapely
from declare_split_legacy105_connected_region import ROOT, REV, sha
from render_split_remaining_corner_families import sections
from tactical_alignment_audit import vector_lines
from tactical_alignment_composite import explicit_warp


def main(out, selected_objects, box):
    out.mkdir(exist_ok=False)
    geometry=ROOT/'supplemented-v2/world/split/geometry.npz'
    metadata=geometry.with_suffix('.json');objects=json.loads(metadata.read_text())['objects']
    with np.load(geometry) as data:points,faces=data['points'],data['faces']
    wp=REV/'display-warps-v1/split.display-warp.json.gz';w=json.loads(gzip.decompress(wp.read_bytes()))
    matrix=np.column_stack((w['projection']['axisU'],w['projection']['axisV']));origin=np.array(w['projection']['origin'])
    ws=np.array(w['sourceNativeMeters']).reshape(-1,2)@matrix.T+origin;wt=np.array(w['targetAttackSvg']).reshape(-1,2)
    warp=explicit_warp(ws,wt-ws,np.array(w['triangles']).reshape(-1,3))
    box=np.array(box);native=(np.array([box[:2],box[2:]])-origin)@np.linalg.inv(matrix).T
    low,high=native.min(0),native.max(0)
    inventory=[];near=[];source_ids=[];object_ids=[]
    for i,obj in enumerate(objects):
        bounds=np.array(obj['boundsMeters'])
        if (bounds[1,:2]<low).any() or (bounds[0,:2]>high).any() or bounds[1,2]<2. or bounds[0,2]>8.5:continue
        ids=np.arange(obj['firstFace'],obj['firstFace']+obj['faceCount']);tri=points[faces[ids]]
        selected=(tri[:,:,:2].max(1)>=low).all(1)&(tri[:,:,:2].min(1)<=high).all(1)&(tri[:,:,2].max(1)>=2.)&(tri[:,:,2].min(1)<=8.5)
        if not selected.any():continue
        inventory.append(dict(object=i,path=obj['path'],completeObjectFaces=len(ids),nearbyRawFaces=ids[selected].tolist(),boundsMeters=obj['boundsMeters']))
        near.extend(tri[selected]);source_ids.extend(ids[selected]);object_ids.extend([i]*int(selected.sum()))
    near=np.array(near);source_ids=np.array(source_ids);object_ids=np.array(object_ids)
    projected=near.copy();projected[:,:,:2]=near[:,:,:2]@matrix.T+origin
    original_lines=vector_lines(Path('assets/maps/split_map.svg'))
    fig,axes=plt.subplots(2,3,figsize=(15,10));colors=['#187c3b','#8c42b3','#2b70cf','#d22a28','#c87714','#d326a0']
    assert len(selected_objects)<=len(colors)
    section_rows=[]
    for ax,z in zip(axes.flat,[2.75,3.25,4.85,5.75,6.75,8.25]):
        lines,indices=sections(projected,z)
        for line in original_lines:ax.plot(*line.T,color='#2b2015',linewidth=1.8)
        unreviewed=~np.isin(object_ids[indices],selected_objects)
        ax.add_collection(LineCollection([warp.apply(x) for x in lines[unreviewed]],colors='#adb1b5',linewidths=.65,alpha=.7))
        records=[]
        for obj,color in zip(selected_objects,colors):
            chosen=object_ids[indices]==obj
            ax.add_collection(LineCollection([warp.apply(x) for x in lines[chosen]],colors=color,linewidths=1.0,label=str(obj)))
            for index,line in zip(indices[chosen],lines[chosen]):records.append(dict(object=obj,rawSourceFace=int(source_ids[index]),displayedSourceSegment=warp.apply(line).tolist()))
        ax.set_xlim(box[0],box[2]);ax.set_ylim(box[3],box[1]);ax.set_aspect('equal');ax.grid(alpha=.2)
        ax.set_title(f'Original absolute Z {z:g} m');ax.legend(fontsize=8)
        section_rows.append(dict(originalZ=z,selectedSourceSections=records))
    fig.suptitle('Split sewer entrance corner, original source sections over unchanged SVG\nBlack SVG; colored complete nearby shell sections; gray all other nearby source. No geometry moved.')
    fig.tight_layout(rect=[0,0,1,.94]);fig.savefig(out/'original-height-six-sections.png',dpi=160);plt.close(fig)
    np.savez_compressed(out/'nearby-original-source.npz',rawSourceFaces=source_ids,sourceObjectIds=object_ids,originalTriangles=near)
    report=dict(scope=__doc__,sourceGeometrySha256=sha(geometry),sourceMetadataSha256=sha(metadata),displayWarpSha256=sha(wp),
        scriptSha256=sha(Path(__file__)),sourcePacketSha256=sha(out/'nearby-original-source.npz'),inventory=inventory,sections=section_rows,
        selectedAuthoredSegments=[dict(edge=i,points=original_lines[i].tolist()) for i in range(108,112)],
        warning='An earlier endpoint test aimed at108 across the109-111 notch. The nearer source shell must be reviewed against that notch, not blindly shifted to the farther108 line. Z4.85 is a standing reference on the extracted3.1m nav floor; other heights are source profile controls.')
    (out/'report.json').write_text(json.dumps(report,indent=2)+'\n')
    print(json.dumps(dict(objects=len(inventory),nearbyRawFaces=len(near),output=str(out))))


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--out',type=Path,default=REV/'split-sewer108-connected-source-review-v1')
    parser.add_argument('--objects',type=int,nargs='+',default=[7897,7895,6163,6169])
    parser.add_argument('--box',type=float,nargs=4,default=[388.,277.,401.,295.])
    args=parser.parse_args();main(args.out,args.objects,args.box)

"""Original-height and complete nearby-source context for the105 proposal."""
import gzip
import json
from pathlib import Path

import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
from matplotlib.collections import LineCollection
import numpy as np
import shapely

from authored_region_cells import barycentric
from declare_split_legacy105_connected_region import ROOT, REV, sha
from render_split_remaining_corner_families import sections
from tactical_alignment_composite import explicit_warp


def main():
    out=REV/'split-legacy105-connected-region-proposal-v2'
    path=out/'region-declaration.json'; family=json.loads(path.read_text())
    source=np.array(family['sourceVerticesSvg']);target=np.array(family['targetVerticesSvg']);cells=np.array(family['triangles'])
    polygons=shapely.polygons(source[cells]);tree=shapely.STRtree(polygons)
    w=json.loads(gzip.decompress((REV/'display-warps-v1/split.display-warp.json.gz').read_bytes()))
    matrix=np.column_stack((w['projection']['axisU'],w['projection']['axisV']));origin=np.array(w['projection']['origin'])
    ws=np.array(w['sourceNativeMeters']).reshape(-1,2)@matrix.T+origin
    wt=np.array(w['targetAttackSvg']).reshape(-1,2);wc=np.array(w['triangles']).reshape(-1,3)
    forward=explicit_warp(ws,wt-ws,wc)
    field=explicit_warp(source,target-source,cells)
    raw_path=ROOT/'supplemented-v2/world/split/geometry.npz'
    data=np.load(raw_path);points=data['points'];faces=data['faces']
    metadata=json.loads(raw_path.with_suffix('.json').read_text())
    inventory_path=REV/'split-legacy105-connected-region-proposal-v1/near-source-inventory.json'
    inventory=json.loads(inventory_path.read_text())
    all_ids=np.unique(np.concatenate([r['faces'] for r in inventory['objects']]))
    selected_ids=np.array(family['reviewedSourceFaces'])
    def triangles(ids):
        result=points[faces[ids]].copy();result[:,:,:2]=result[:,:,:2]@matrix.T+origin;return result
    selected=triangles(selected_ids)
    other=triangles(np.setdiff1d(all_ids,selected_ids))
    domain=shapely.box(*family['box'])
    def mapped_lines(lines):
        result=[]
        for line in lines:
            segment=shapely.LineString(line)
            for cell in tree.query(segment,predicate='intersects'):
                for part in shapely.get_parts(shapely.intersection(segment,polygons[cell])):
                    if not isinstance(part,shapely.LineString) or part.length==0:continue
                    p=np.array(part.coords);result.append(barycentric(p,source[cells[cell]])@target[cells[cell]])
            for part in shapely.get_parts(shapely.difference(segment,domain)):
                if isinstance(part,shapely.LineString) and part.length>0:
                    result.append(forward.apply(np.array(part.coords)))
        return result
    spans=[np.array([f['startSvg'],f['endSvg']]) for f in family['reviewedAuthoredSpans']]
    spans.append(np.array([[292.365,310.928],[363.603,310.928]]))
    views=[('top-and-true104',[275,273,299,293]),('lower-and-roof-frontier',[280,297,319,332])]
    for name,box in views:
        fig,axes=plt.subplots(2,3,figsize=(16,10))
        for ax,z in zip(axes.flat,[4.75,5.75,6.75,8.25,11.053729057312012,11.172919273376465]):
            original,_=sections(selected,z);others,_=sections(other,z)
            ax.add_collection(LineCollection([forward.apply(s) for s in others],colors='#94a3b8',lw=.8,alpha=.65,label='All nearby raw source; membership unchanged'))
            ax.add_collection(LineCollection([forward.apply(s) for s in original],colors='#dc2626',lw=1.3,label='Selected original source'))
            ax.add_collection(LineCollection(mapped_lines(original),colors='#16a34a',lw=1.3,label='Proposed continuous field'))
            ax.add_collection(LineCollection(spans,colors='#111827',lw=2,label='Reviewed SVG wall'))
            ax.set_xlim(box[0],box[2]);ax.set_ylim(box[3],box[1]);ax.set_aspect('equal');ax.grid(alpha=.2)
            ax.set_title(f'Absolute source Z={z:.6f}m');ax.legend(fontsize=6,loc='best')
        fig.suptitle('Proposal only: original-height slices. Gray includes every nearby source object, not a blocker-role claim.\nNo source height is added; selected wall, generator and roof share a finite XY field.',fontsize=11)
        fig.tight_layout();fig.savefig(out/f'{name}-original-height-preview.png',dpi=150);plt.close(fig)
    contacts=[]
    for edge,start,end,target_start,target_end in [
        (103,[279.28622987276356,280.8797487438403],[279.28622987276356,288.6989892960074],[279.074,281.157],[279.074,288.068]),
        (104,[279.28622987276356,280.8797487438403],[291.0197140465251,280.8797487438403],[279.074,281.157],[292.365,281.157]),
        (105,[291.0197140465251,280.8797487438403],[291.0197140465251,312.1567706085799],[292.365,281.157],[292.365,310.928])]:
        p=np.linspace(start,end,1001);q=field.apply(p);a=np.array(target_start);b=np.array(target_end);t=(b-a)/np.linalg.norm(b-a);n=np.array([-t[1],t[0]])
        contacts.append(dict(edge=edge,sourceEndpoints=[start,end],targetEndpoints=[target_start,target_end],samples=len(p),maximumNormalErrorSvg=float(np.max(abs((q-a)@n))),mappedAlongRange=[float(np.min((q-a)@t)),float(np.max((q-a)@t))]))
    neighbor=family['neighbor106Contact'];neighbor['actualMappedSvg']=field.apply(np.array([neighbor['sourceSvg']]))[0].tolist();neighbor['maximumJoinErrorSvg']=float(np.linalg.norm(np.array(neighbor['actualMappedSvg'])-neighbor['targetSvg']))
    report=dict(declarationSha256=sha(path),sourceGeometrySha256=sha(raw_path),scriptSha256=sha(Path(__file__)),
        nearbySourceInventorySha256=sha(inventory_path),selectedSourceFaces=len(selected_ids),nearbyRawObjects=len(inventory['objects']),
        sourceRoles=[dict(object=i,path=metadata['objects'][i]['path'],firstFace=metadata['objects'][i]['firstFace'],faceCount=metadata['objects'][i]['faceCount']) for i in family['objects']],
        contacts=contacts,neighbor106=neighbor,
        supersededFinding='The earlier five-object packet omitted7899. Rays ending at y280.95 had not reached its y280.8797487 horizontal wall. Therefore that packet cannot support the old no-horizontal104-wall inference.',
        fullRangeReplay='split-legacy105-frontier-review-v2/source-nav-rays.json',
        scopeLimit='Source-section and declaration proposal only. No changed pack, original-height candidate oracle, or actual rendered candidate is claimed. Gray nearby source remains a geometry review queue; packed material policy still applies.')
    (out/'source-profile-review.json').write_text(json.dumps(report,indent=2)+'\n')
    print(json.dumps(dict(contacts=contacts,neighbor106=neighbor)))


if __name__=='__main__':main()

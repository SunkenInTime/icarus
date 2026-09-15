"""Independent connected-building contact proof and full source-height review."""
import gzip
import io
import json
from pathlib import Path

import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
from matplotlib.collections import LineCollection
import numpy as np
from PIL import Image, ImageDraw
import resvg_py
import shapely

from authored_region_cells import barycentric
from declare_split_asite_return18_region import ROOT, REV, sha
from render_split_remaining_corner_families import sections
from tactical_alignment_audit import vector_lines
from tactical_alignment_composite import explicit_warp
from verify_region_mapping import verify_rank_one_declarations
from verify_region_contacts_exact import exact_wall_gate


def main():
    out=REV/'split-asite-building-connected-proposal-v6'
    path=out/'region-declaration.json';family=json.loads(path.read_text())
    report_path=out/'continuous-source-review.json';assert not report_path.exists()
    s=np.array(family['sourceVerticesSvg']);t=np.array(family['targetVerticesSvg']);c=np.array(family['triangles']);rank=verify_rank_one_declarations(family)
    polygons=shapely.polygons(s[c]);tree=shapely.STRtree(polygons);field=explicit_warp(s,t-s,c)
    raw_path=ROOT/'supplemented-v2/world/split/geometry.npz';raw=np.load(raw_path);metadata=json.loads(raw_path.with_suffix('.json').read_text())
    wp=REV/'display-warps-v1/split.display-warp.json.gz';w=json.loads(gzip.decompress(wp.read_bytes()));matrix=np.column_stack((w['projection']['axisU'],w['projection']['axisV']));origin=np.array(w['projection']['origin'])
    ws=np.array(w['sourceNativeMeters']).reshape(-1,2)@matrix.T+origin;wt=np.array(w['targetAttackSvg']).reshape(-1,2);wc=np.array(w['triangles']).reshape(-1,3);forward=explicit_warp(ws,wt-ws,wc)
    meshes={};ids={}
    for oid in family['objects']:
        obj=metadata['objects'][oid];ids[oid]=np.arange(obj['firstFace'],obj['firstFace']+obj['faceCount'])
        tri=raw['points'][raw['faces'][ids[oid]]].astype(float);tri[:,:,:2]=tri[:,:,:2]@matrix.T+origin;meshes[oid]=tri
    coordinate_evidence=[]
    def coord(oid,axis,near,z=3.75):
        values=meshes[oid][:,:,axis].ravel();v=float(values[np.argmin(abs(values-near))]);method='stored original vertex'
        if abs(v-near)>=1e-5:
            seg,index=sections(meshes[oid],z);values=seg[:,:,axis].ravel();v=float(values[np.argmin(abs(values-near))]);method='original triangle section'
        assert abs(v-near)<1e-5,(oid,axis,near,v)
        coordinate_evidence.append(dict(object=oid,axis=axis,value=v,method=method,sectionZ=z if method=='original triangle section' else None));return v
    left=coord(5857,0,388.028614);right=coord(5857,0,408.308322);plinth=coord(5857,0,408.117274)
    top=coord(5857,1,58.073868);bottom=coord(5857,1,85.441210)
    specs=[
        (17,'original standing top',[[coord(5857,0,345.754398),top],[right,top]]),
        (18,'original standing return',[[right,top],[right,bottom]]),
        (18,'original low plinth',[[plinth,coord(5857,1,58.176256,z=2.1)],[plinth,coord(5857,1,85.343464)]]),
        (19,'original lower standing wall',[[left,bottom],[right,bottom]]),
        (20,'finite right jamb near side',[[family['connectedBuildingSources']['rightJambDepthBand'][0],float(meshes[430][:,:,1].min())],[family['connectedBuildingSources']['rightJambDepthBand'][0],float(meshes[430][:,:,1].max())]]),
        (20,'finite frame far side',[[float(meshes[430][:,:,0].max()),float(meshes[430][:,:,1].min())],[float(meshes[430][:,:,0].max()),float(meshes[430][:,:,1].max())]]),
        (21,'lower turn front',[[coord(5849,0,388.089478),coord(5849,1,89.308378)],[coord(5849,0,390.504028),coord(5849,1,89.308385)]]),
        (22,'lower return',[[coord(5849,0,390.679327),coord(5849,1,89.952879)],[coord(5849,0,390.679327),coord(5849,1,97.091027)]]),
        (23,'long wall standing front',[[coord(5849,0,390.763770),coord(5849,1,97.091027)],[coord(5849,0,433.506654),coord(5849,1,97.067905)]]),
        (23,'long wall upper front',[[coord(5849,0,390.763770),coord(5849,1,96.675670)],[coord(5849,0,433.400470),coord(5849,1,96.675670)]]),
        (24,'ticket exterior standing front',[[coord(5849,0,435.819610),coord(5849,1,99.281570)],[coord(5849,0,435.819610),coord(5849,1,113.582530)]]),
        (24,'ticket interior backing',[[float(meshes[5858][:,:,0].min()),float(meshes[5858][:,:,1].min())],[float(meshes[5858][:,:,0].min()),float(meshes[5858][:,:,1].max())]]),
        (25,'outer bottom wall',[[coord(5849,0,435.624090),coord(5849,1,115.238580)],[coord(5849,0,466.369459),coord(5849,1,115.108115)]]),
        (25,'ticket interior bottom',[[float(meshes[5858][:,:,0].min()),float(meshes[5858][:,:,1].max())],[float(meshes[5858][:,:,0].max()),float(meshes[5858][:,:,1].max())]]),
        (73,'opposite doorway short turn',[[coord(5849,0,371.313878),coord(5849,1,89.308360)],[coord(5849,0,374.040030),coord(5849,1,89.308360)]]),
        (74,'opposite finite jamb near',[[family['leftShellContract']['oppositeJambDepthBand'][0],float(meshes[430][:,:,1].min())],[family['leftShellContract']['oppositeJambDepthBand'][0],float(meshes[430][:,:,1].max())]]),
        (74,'opposite finite jamb far',[[family['leftShellContract']['oppositeJambDepthBand'][1],float(meshes[430][:,:,1].min())],[family['leftShellContract']['oppositeJambDepthBand'][1],float(meshes[430][:,:,1].max())]]),
        (75,'complete finite lower-left shell',[[coord(5857,0,349.664063),bottom],[coord(5857,0,374.005187),bottom]]),
        (76,'left inner return',[[coord(5857,0,349.664063),coord(5857,1,75.665758)],[coord(5857,0,349.664063),bottom]]),
        (77,'left finite doorway lower jamb',[[coord(5857,0,345.754398),coord(5857,1,75.667189,z=2.1)],[coord(5857,0,349.664063),coord(5857,1,75.667189,z=2.1)]]),
        (78,'finite outer-left standing wall',[[coord(5853,0,345.499502),coord(5853,1,98.145190)],[coord(5853,0,345.499502),float(meshes[5853][:,:,1].max())]])]
    lines=vector_lines(Path('assets/maps/split_map.svg'))
    contacts=[]
    for e,name,segment in specs:
        print('Checking',e,name,flush=True)
        contacts.append(dict(edge=e,name=name,**exact_wall_gate(family,segment,lines[e].tolist())))
    # Intersect both stored fields. Endpoint agreement proves every affine
    # fragment throughout the inherited upper region, including its boundary.
    old_path=REV/'split-asite-building-connected-proposal-v4/region-declaration.json';old=json.loads(old_path.read_text());os=np.array(old['sourceVerticesSvg']);ot=np.array(old['targetVerticesSvg']);oc=np.array(old['triangles']);op=shapely.polygons(os[oc]);old_tree=shapely.STRtree(op)
    upper=shapely.difference(shapely.box(*family['box']),shapely.box(*family['leftShellContract']['priorFieldBoundary']));maximum=0.;parts=0
    for index,polygon in enumerate(polygons):
        clipped=shapely.intersection(polygon,upper)
        if clipped.is_empty or clipped.area==0:continue
        for old_index in old_tree.query(clipped,predicate='intersects'):
            pts=shapely.get_coordinates(shapely.intersection(clipped,op[old_index]))
            if not len(pts):continue
            q=barycentric(pts,s[c[index]])@t[c[index]];expected=barycentric(pts,os[oc[old_index]])@ot[oc[old_index]]
            maximum=max(maximum,float(np.linalg.norm(q-expected,axis=1).max()));parts+=1
    assert maximum<1e-10
    source_lower=np.array([342.,54.,-.05]);source_upper=np.array([472.,118.,13.5])
    native_bounds=(np.array([source_lower[:2],source_upper[:2]])-origin)@np.linalg.inv(matrix).T
    lo=np.r_[native_bounds.min(0),source_lower[2]];hi=np.r_[native_bounds.max(0),source_upper[2]]
    retained=set(np.load(REV/'full-height-input-v1/split/source-correspondence.npz')['sourceFaces'].tolist())
    inventory=[]
    for oid,obj in enumerate(metadata['objects']):
        a,b=np.array(obj['boundsMeters'])
        if np.any(b<lo) or np.any(a>hi):continue
        ff=np.arange(obj['firstFace'],obj['firstFace']+obj['faceCount']);native=raw['points'][raw['faces'][ff]].astype(float)
        hit=(native.max(1)>=lo).all(1)&(native.min(1)<=hi).all(1)
        if not hit.any():continue
        tri=native.copy();tri[:,:,:2]=tri[:,:,:2]@matrix.T+origin;meshes[oid]=tri;ids[oid]=ff
        inventory.append(dict(object=oid,path=obj['path'],originalBoundsMeters=obj['boundsMeters'],originalFaceCount=len(ff),
            overlapOriginalFaceIds=ff[hit].tolist(),retainedOriginalFaceCount=sum(int(i) in retained for i in ff),proposedMember=oid in family['objects']))

    def mapped(line):
        output=[]
        segment=shapely.LineString(line)
        for cell in tree.query(segment,predicate='intersects'):
            for part in shapely.get_parts(shapely.intersection(segment,polygons[cell])):
                if not isinstance(part,shapely.LineString) or part.length==0:continue
                p=np.array(part.coords);weights=barycentric(p,s[c[cell]]);q=weights@t[c[cell]]
                if int(cell) in rank:
                    r=rank[int(cell)];a,b=r['endpoints'];q=a+(weights@r['parameters'])[:,None]*(b-a)
                output.append(q)
        return output
    heights=[1.75,2.1,3.75,5.5,6.05,7.05,7.5,8.9];cache={}
    for z in heights:
        rows={}
        for oid,tri in meshes.items():
            seg,index=sections(tri,z);before=[];after=[]
            for line,i in zip(seg,index):
                if int(ids[oid][i]) not in retained or np.linalg.norm(line[1]-line[0])==0:continue
                original=forward.apply(line);before.append(original)
                if oid in family['objects']:after.extend(mapped(line))
                else:after.append(original)
            if before:rows[oid]=(before,after)
        cache[z]=rows
    fig,axes=plt.subplots(2,4,figsize=(24,13))
    for ax,z in zip(axes.flat,heights):
        for oid,(before,after) in cache[z].items():
            ax.add_collection(LineCollection(before,colors='#aaaaaa',linewidths=.5,alpha=.4))
            ax.add_collection(LineCollection(after,colors='#2386bc' if oid in family['objects'] else '#d58a33',linewidths=.85))
        for e in [*range(17,29),*range(73,80)]:ax.plot(*lines[e].T,color='#b8293e',lw=.8,ls='--')
        ax.set_xlim(342,473);ax.set_ylim(119,53);ax.set_aspect('equal');ax.set_title(f'Absolute source Z {z:g} m');ax.grid(alpha=.15)
    fig.suptitle('Connected A-site building source sections. Blue proposed members, orange unchanged source, gray original position, red actual authored contours.\nSource Z and height openings are retained. Material admission is frozen; section overlays do not sample alpha and are not rendered cones.')
    fig.tight_layout(rect=[0,0,1,.95]);fig.savefig(out/'eight-original-height-building-sections.png',dpi=130);plt.close(fig)
    reflection=np.array(w['attackToDefenseSvg']['origin'])
    focuses={'lower-doorframe':[[370,81],[396,100]],'left-doorframe':[[342,53],[354,103]],'long-wall':[[388,92],[440,100]],'ticket-corner':[[430,92],[470,119]],'building':[[342,53],[473,119]]}
    for side in ['attack','defense']:
        svg=Path('assets/maps/split_map'+('_defense' if side=='defense' else '')+'.svg')
        base=Image.open(io.BytesIO(resvg_py.svg_to_bytes(svg_string=svg.read_text(),zoom=8,background='#101014'))).convert('RGB')
        convert=lambda p:reflection-np.array(p) if side=='defense' else np.array(p)
        for name,bounds in focuses.items():
            bb=convert(bounds);lower=np.floor(bb.min(0)*8).astype(int);upper=np.ceil(bb.max(0)*8).astype(int)
            for kind,entry in [('source',0),('proposal',1)]:
                image=base.crop(tuple(np.r_[lower,upper]));draw=ImageDraw.Draw(image)
                for oid,pair in cache[3.75].items():
                    for line in pair[entry]:
                        draw.line([tuple(p) for p in convert(line)*8-lower],fill='#65c7ff' if oid in family['objects'] else '#e39441',width=1)
                image.save(out/f'{side}-{name}-{kind}-native8x.png')
    report=dict(declarationSha256=sha(path),scriptSha256=sha(Path(__file__)),sourceGeometrySha256=sha(raw_path),productionMutation=False,
        contacts=contacts,coordinateEvidence=coordinate_evidence,upperFieldInheritance=dict(priorDeclarationSha256=sha(old_path),affineIntersections=parts,maximumErrorSvg=maximum),
        unfilteredInventory=inventory,proposedObjects=family['objects'],sourceFaceCount=len(family['reviewedSourceFaces']),
        scope='Finite A-site building, complete exterior and ticket interior, both doorways, inner/outer-left shells and mounted details. Original source Z/UV and separate roof/doorway heights remain authoritative.',
        terminalConditions='5849 has a finite upward cap at the25 endpoint. Separate5893/5894 lower wall begins farther below, with different heights and an original positive source gap. Those remain explicit neighboring controls.',
        pending=['Original-height first hits and exact source partition.','Root inspection of the expanded role inventory and both-side images.','All-map/runtime/standing-floor policy remains separate.'])
    report_path.write_text(json.dumps(report,indent=2)+'\n')
    print(json.dumps(dict(contacts=len(contacts),normalError=max(r['maximumNormalErrorSvg'] for r in contacts),upperInheritanceError=maximum,inventory=len(inventory))))


if __name__=='__main__':main()

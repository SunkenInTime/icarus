"""Encode the inspected Sunset wall/source associations and explicit box tops."""
import copy
import json
import re
from pathlib import Path
import xml.etree.ElementTree as ET

import numpy as np
import shapely

from audit_svg_source_height_associations import ROOT,REV
from compile_reviewed_svg_height_map import polygon,rings
from build_split_svg_semantic_prototype import contours


def main():
    model=json.loads((REV/'all-map-svg-footprints-v1/sunset-attack.json').read_text())
    ranked=json.loads((REV/'all-map-svg-height-candidates-v1/sunset.json').read_text())
    raw=np.load(ROOT/'supplemented-v2/world/sunset/geometry.npz');points,faces=raw['points'],raw['faces']
    objects=json.loads((ROOT/'supplemented-v2/world/sunset/geometry.json').read_text())['objects']
    a=np.array(json.loads((ROOT/'tactical-alignment-sides-v1/sunset.json').read_text())['nativeToAttackSvg']);inverse=np.linalg.inv(a[:,:2])
    by_id={w['id']:w for w in model['walls']}
    overrides={
        'p3-stroke-1':[6186,6187], 'p7-stroke-9':[5930,5931],
        'p5-stroke-0':[6168], 'p6-stroke-0':[6169],
        'p7-stroke-4':[6269], 'p7-stroke-15':[5282,5283],
        'p7-stroke-16':[4643,4645,4646], 'p7-stroke-19':[4776,4777],
        'p9-stroke-2':[7344,7345],
        'p9-stroke-4':[5890], 'p9-stroke-5':[1035],
        'p9-stroke-6':[1034,5890,1224], 'p11-stroke-0':[5890,1225],
        'p11-stroke-1':[1218], 'p9-stroke-3':[6862,6863],
        'p9-stroke-7':[5631,5676,5695,5632],
    }
    floors={'p5-stroke-0':2.,'p6-stroke-0':2.,'p4-stroke-0':2.,
            'p9-stroke-1':2.,'p9-stroke-3':3.,'p9-stroke-7':1.}
    terrain={'p9-stroke-0':[6070,6071,6072,6076],'p10-stroke-0':[7353]}
    decisions=[]
    for candidate in ranked['walls']:
        wid=candidate['wallId'];source_ids=overrides.get(wid,candidate['selectedSourceObjects'])
        decision=dict(wallId=wid,reviewStatus='reviewed',mode='source-height',
            floorElevationMeters=floors.get(wid,candidate['floorElevationMeters']),
            maximumSourceZ=max(objects[i]['boundsMeters'][1][2] for i in source_ids),
            selectedSourceObjects=source_ids,
            label=' / '.join(objects[i]['path'].split('/')[1] for i in source_ids),
            reason='Source footprint and local vertical-face correspondence inspected against the literal SVG. Retain source assembly maximum; cosmetic mesh gaps do not open cover.')
        if wid.startswith('p2-fill-'):
            decision.update(mode='solid',maximumSourceZ=None,
                reason='Authored enclosing building/wall assembly. Keep the structural silhouette solid; roof height variations do not create a usable view through this outline.')
        if wid in terrain:
            decision.update(mode='connected-ground',selectedSourceObjects=terrain[wid],
                reason='Authored floor-level transition. Continuous source floor/ramp spans the line; isolated endpoint structure is already owned by the enclosing SVG wall. Do not add a floor-height blocker.')
        if wid=='p9-stroke-1':
            decision.update(maximumSourceZ=5.000000476837158,
                reason='Mid raised ledge local vertical faces top at 5m across the authored front and return. The remote 14.15m arch roof is not this ledge; adjoining structural pillar belongs to the enclosing wall.')
        if wid in overrides:
            decision['reason']+=' Excluded nearby roof/billboard, decorative foliage, or unrelated adjacent wall from this represented prop.'
        if wid=='p8-stroke-0':
            decision['parts']=[]
            for label,oid,clip in [('medium',6718,shapely.box(-1000,-1000,78.903,1000)),('small',6719,shapely.box(78.903,-1000,1000,1000))]:
                for i,p in enumerate(shapely.get_parts(polygon(by_id[wid]).intersection(clip))):
                    if p.geom_type!='Polygon' or p.area<1e-10:continue
                    decision['parts'].append(dict(id=f'{label}-{i}',reviewStatus='reviewed',mode='source-height',
                        rings=rings(p),clipBox=list(clip.bounds),fillRule='evenodd',floorElevationMeters=4.,
                        maximumSourceZ=objects[oid]['boundsMeters'][1][2],selectedSourceObjects=[oid],
                        reason='Distinct represented planter heights. The taller planter owns the entire shared 0.5-unit stroke.'))
        if wid=='p7-stroke-8':
            middle=shapely.Polygon([[184.69,224.887],[189.509,220.321],[194.329,225.789],[189.509,230.074]])
            cut=middle.buffer(.5,join_style='mitre')
            decision['parts']=[dict(id='middle',mode='source-height',clipRings=rings(cut),
                fillRule='evenodd',floorElevationMeters=2.,maximumSourceZ=6.002176284790039,
                selectedSourceObjects=[7162],reason='Source-confirmed taller middle box. Authored divider owns its complete 1-unit stroke.'),
                dict(id='ends',mode='source-height',remainder=True,floorElevationMeters=2.,
                maximumSourceZ=4.0022,selectedSourceObjects=[7162],reason='Both end boxes have horizontal source tops at 4m; they do not inherit the 6m middle height.')]
        decisions.append(decision)
    # Explicit top domains are author-drawn contours. Closing a U-shaped cover
    # uses its authored endpoints, never a replacement source mesh outline.
    supports=[];support_checks=[]
    selected_supports={'p3-stroke-0','p3-stroke-1','p5-stroke-0','p6-stroke-0',
        'p7-stroke-2','p7-stroke-10','p11-stroke-1',
        'p7-stroke-0','p7-stroke-6','p7-stroke-7','p7-stroke-8',
        'p7-stroke-9','p7-stroke-12','p7-stroke-13','p7-stroke-14',
        'p7-stroke-16','p7-stroke-17','p7-stroke-18','p7-stroke-19',
        'p9-stroke-2','p11-stroke-2'}
    for d in decisions:
        if d['wallId'] not in selected_supports:continue
        wall=by_id[d['wallId']];e=ET.Element(wall['element'],wall['source']['attributes'])
        assert wall['source']['transform'] is None
        choices=[]
        for xy,_ in contours(e):
            if len(np.unique(xy,axis=0))<3:continue
            domain=shapely.make_valid(shapely.Polygon(xy))
            if domain.geom_type!='Polygon' or domain.area<1:continue
            contact=domain.boundary.buffer(.6).intersection(polygon(wall)).area
            if contact>=polygon(wall).area*.75:choices.append(domain)
        if not choices:continue
        domain=min(choices,key=lambda p:p.area)
        xy=np.array(domain.representative_point().coords)[0];native=inverse@(xy-a[:,2]);hits=[]
        for oid in d['selectedSourceObjects']:
            o=objects[oid];ids=np.arange(o['firstFace'],o['firstFace']+o['faceCount']);t=points[faces[ids]].astype(float)
            # Mirrored instances can reverse winding. Highest intersection,
            # rather than normal sign, distinguishes top from underside.
            normals=np.cross(t[:,1]-t[:,0],t[:,2]-t[:,0]);n=np.linalg.norm(normals,axis=1);keep=(abs(normals[:,2])>.65*n)&(n>1e-10)
            for fid,tri in zip(ids[keep],t[keep]):
                if not shapely.Polygon(tri[:,:2]).covers(shapely.Point(native)):continue
                plane=np.linalg.solve(np.c_[tri[:,:2],np.ones(3)],tri[:,2]);z=float(plane[:2]@native+plane[2]);hits.append((z,oid,int(fid)))
        if not hits:
            support_checks.append(dict(wallId=d['wallId'],status='no-center-top-hit'));continue
        z,oid,fid=max(hits)
        if z-d['floorElevationMeters']<.3:continue
        supports.append(dict(id=d['wallId']+'-top',label=d['label'].replace('_',' '),
            reviewStatus='reviewed',rings=rings(domain),fillRule='evenodd',
            floorElevationMeters=d['floorElevationMeters'],surfaceElevationMeters=z,
            heightAboveFloorMeters=z-d['floorElevationMeters'],sourceObjects=[oid],sourceFace=fid,
            sourceSampleNative=native.tolist(),
            accessibilityLimitation='Explicit top selection; climbability is not inferred or added to pathfinding.'))
    for label,xy,z in [
        ('middle',[[184.69,224.887],[189.509,220.321],[194.329,225.789],[189.509,230.074]],6.),
        ('south',[[184.69,224.887],[181.476,227.931],[186.832,233.287],[189.509,230.074]],4.),
        ('north',[[189.509,220.321],[191.652,218.292],[197.007,223.112],[194.329,225.789]],4.),
    ]:
        supports.append(dict(id=f'mid-cover-{label}-top',label=f'Mid cover {label} box',
            reviewStatus='reviewed',rings=rings(shapely.Polygon(xy)),fillRule='evenodd',
            floorElevationMeters=2.,surfaceElevationMeters=z,heightAboveFloorMeters=z-2.,sourceObjects=[7162]))
    for label,bounds,oid in [('medium',[72.2266,146.529,78.653,153.491],6718),
                             ('small',[78.653,150.01,82.4018,153.491],6719)]:
        z=objects[oid]['boundsMeters'][1][2]
        supports.append(dict(id=f'market-{label}-planter-top',label=f'{label.title()} planter',
            reviewStatus='reviewed',rings=rings(shapely.box(*bounds)),fillRule='evenodd',
            floorElevationMeters=4.,surfaceElevationMeters=z,heightAboveFloorMeters=z-4.,sourceObjects=[oid]))
    # A central ray can fall through a decorative lid opening. Keep only source
    # top domains near the selected standing surface, not the bin's underside.
    for support in supports:
        if support['id']=='p6-stroke-0-top':
            support.update(surfaceElevationMeters=2.98615275,heightAboveFloorMeters=.98615275)
        domain=polygon(support);faces_at_top=[];higher_faces=[]
        for oid in support['sourceObjects']:
            obj=objects[oid];t=points[faces[obj['firstFace']:obj['firstFace']+obj['faceCount']]].astype(float)
            n=np.cross(t[:,1]-t[:,0],t[:,2]-t[:,0]);length=np.linalg.norm(n,axis=1)
            good=(abs(n[:,2])>.65*length)&(length>1e-10)&(abs(t[:,:,2]-support['surfaceElevationMeters']).max(axis=1)<.12)
            faces_at_top.extend(shapely.polygons(t[good,:,:2]@a[:,:2].T+a[:,2]))
            higher=(abs(n[:,2])>.65*length)&(length>1e-10)&(t[:,:,2].min(axis=1)>support['surfaceElevationMeters']+.12)
            higher_faces.extend(shapely.polygons(t[higher,:,:2]@a[:,:2].T+a[:,2]))
        clipped=domain.intersection(shapely.union_all(faces_at_top)).difference(shapely.union_all(higher_faces))
        clean=[]
        for p in shapely.get_parts(clipped):
            if p.geom_type!='Polygon' or p.area<1e-8:continue
            clean.append(shapely.Polygon(p.exterior,[r for r in p.interiors if shapely.Polygon(r).area>1e-10]))
        assert clean,('No top coverage',support['id'])
        support['rings']=[r for p in clean for r in rings(p)]
        support['sourceDomainCoverage']=shapely.union_all(clean).area/domain.area
        # Display names describe the represented prop rather than mesh-export
        # categories such as Shell_5 or Props_0.
        label=support['label'].split(' / ')[0]
        label=re.sub(r'^(?:Shell|Props|Interior|Cover|Street)\s+\d+\s+','',label)
        label=re.sub(r'([a-z])([A-Z])',r'\1 \2',label)
        label=re.sub(r'([AB])(?=Site|Main|Lobby|Link|Market)',r'\1 ',label)
        label=re.sub(r'\b(?:A|B|C)\d*$', '',label).strip()
        support['label']=label
    out=REV/'sunset-svg-height-decisions-v1';out.mkdir(exist_ok=True)
    output=dict(map='sunset',walls=decisions,supports=supports,supportChecks=support_checks,
        groundModel=str(REV/'sunset-reviewed-ground-v1/sunset.json.gz'),
        groundReviewStatus='reviewed',
        reviewEvidence='Root inspected all 50 orange/blue SVG/source correspondence plots in all-map-svg-height-source-review-v1/sunset; floor/ledge evidence examined separately.',
        limitations=['Final cone rendering and source-ground integration checks still required.',
                     'Finite assembly maxima preserve cosmetic gaps as solid. Dynamic door states are outside this pass.'])
    (out/'sunset.json').write_text(json.dumps(output,indent=2,allow_nan=False)+'\n')
    print(json.dumps(dict(walls=len(decisions),supports=len(supports),supportChecks=support_checks)))


if __name__=='__main__':main()

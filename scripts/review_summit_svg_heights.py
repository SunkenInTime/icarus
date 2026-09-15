"""Summit SVG wall heights, including attached crates inside compound paths."""
import json

import numpy as np
import shapely

from audit_svg_source_height_associations import ROOT, REV
from compile_reviewed_svg_height_map import polygon, rings

# Authored inner rings matched to the inspected actual prop assemblies.
PROPS={
 'p1-stroke-0':{1:[6199],2:[6198],3:[5558],4:[5127,5109],5:[5352]},
 'p1-stroke-2':{0:[6197,6210],1:[3317,3318]},
 'p1-stroke-3':{1:[6209],2:[4809,4810]},
 'p1-stroke-5':{0:[6208]},
 'p1-stroke-7':{0:[7122,7123],2:[7126],3:[7124,7251],4:[5945]},
 'p1-stroke-8':{0:[6162,6163]},
 'p1-stroke-9':{0:[4035,4036]},
 'p1-stroke-10':{1:[7125]},
 'p1-stroke-11':{1:[5126,5110]},
 'p1-stroke-12':{1:[6432,6433]},
 'p1-stroke-13':{0:[5122,5123,5124,5125]},
 'p1-stroke-14':{1:[5121]},
 'p1-stroke-16':{0:[5128,5108]},
 'p2-stroke-10':{0:[5273]},
 'p3-stroke-0':{0:[7131]},
}


def main():
    base=json.loads((REV/'all-map-svg-footprints-v1/summit-attack.json').read_text())
    ranked=json.loads((REV/'all-map-svg-height-candidates-v1/summit.json').read_text())
    candidates={w['wallId']:w for w in ranked['walls']}
    source=ROOT/'supplemented-v2/world/summit/geometry.npz';raw=np.load(source)
    objects=json.loads(source.with_suffix('.json').read_text())['objects']
    matrix=np.array(json.loads((ROOT/'tactical-alignment-sides-v1/summit.json').read_text())['nativeToAttackSvg'])
    receiver=shapely.union_all([polygon(r) for r in base['receivers']])
    source_cache={};supports=[];walls=[];evidence=[]
    def geometry(ids):
        key=tuple(ids)
        if key not in source_cache:
            t=np.concatenate([raw['points'][raw['faces'][objects[i]['firstFace']:objects[i]['firstFace']+objects[i]['faceCount']]] for i in ids]).astype(float)
            n=np.cross(t[:,1]-t[:,0],t[:,2]-t[:,0]);length=np.linalg.norm(n,axis=1)
            horizontal=t[(abs(n[:,2])>.85*length)&(length>1e-10)]
            source_cache[key]=(t,horizontal)
        return source_cache[key]
    def add_support(wid,label,domain,ids,floor):
        _,t=geometry(ids)
        if not len(t):return
        area=shapely.area(shapely.polygons(t[:,:,:2]));z=t[:,:,2].mean(axis=1)
        # Pick the highest broad horizontal top, not a tiny bevel or underside.
        groups={float(level):float(area[np.round(z,1)==level].sum()) for level in np.unique(np.round(z,1))}
        broad=[level for level,value in groups.items() if value>=max(groups.values())*.15]
        level=max(broad)
        good=(abs(t[:,:,2]-level).max(axis=1)<.12)
        if not good.any() or level-floor<.3:return
        top=float(np.average(z[good],weights=area[good]))
        coverage=shapely.union_all(shapely.polygons(t[good,:,:2]@matrix[:,:2].T+matrix[:,2]))
        shape=domain.intersection(coverage);parts=[]
        for p in shapely.get_parts(shape):
            if p.geom_type=='Polygon' and p.area>1e-8:
                parts.append(shapely.Polygon(p.exterior,[r for r in p.interiors if shapely.Polygon(r).area>1e-10]))
        if not parts:return
        supports.append(dict(id=wid,label=label,reviewStatus='reviewed',rings=[r for p in parts for r in rings(p)],fillRule='evenodd',
            floorElevationMeters=floor,surfaceElevationMeters=top,heightAboveFloorMeters=top-floor,
            sourceObjects=ids,sourceDomainCoverage=shapely.union_all(parts).area/domain.area,
            accessibilityLimitation='Explicit top selection. Route accessibility is not inferred.'))
    for wall in base['walls']:
        wid=wall['id'];shape=polygon(wall);c=candidates[wid];selected=c['selectedSourceObjects']
        decision=dict(wallId=wid,reviewStatus='reviewed',mode='solid',floorElevationMeters=c['floorElevationMeters'],
            selectedSourceObjects=selected,reason='Inspected represented structural wall. Keep the tactical silhouette solid; exported cosmetic gaps and remote roof geometry do not create gameplay openings.')
        if wid in PROPS:
            width=float(wall['source']['resolvedStyle'].get('stroke-width',1))
            holes=list(shape.interiors)
            # Preserve the full stroke of a tall building wall where a low prop
            # attaches. Void interiors are distinguished from the outer floor.
            structural=[]
            for i,r in enumerate(holes):
                p=shapely.Polygon(r)
                if i not in PROPS[wid] and p.intersection(receiver).area<p.area*.1:structural.append(p.buffer(width,join_style='mitre'))
            protected=shapely.union_all(structural)
            parts=[]
            for i,ids in sorted(PROPS[wid].items(),key=lambda entry:max(objects[j]['boundsMeters'][1][2] for j in entry[1]),reverse=True):
                interior=shapely.Polygon(holes[i]);floor=min(objects[j]['boundsMeters'][0][2] for j in ids)
                # Small buried mesh skirts do not lower the known integer floor.
                if abs(floor-round(floor))<.08:floor=float(round(floor))
                top=max(objects[j]['boundsMeters'][1][2] for j in ids)
                mask=interior.buffer(width,join_style='mitre').difference(protected)
                masks=[p for p in shapely.get_parts(mask) if p.geom_type=='Polygon' and p.area>1e-10]
                parts.append(dict(id=f'prop-{i}',mode='source-height',clipRings=[r for p in masks for r in rings(p)],fillRule='evenodd',
                    floorElevationMeters=floor,maximumSourceZ=top,selectedSourceObjects=ids,
                    reason='Actual named prop inside this authored ring. Tall adjoining SVG wall stroke is protected.'))
                add_support(f'{wid}-prop-{i}-top',f'Summit {objects[ids[0]]["path"].split("/")[0].replace("Plummet_Art_","")} cover',interior.buffer(width/2,join_style='mitre'),ids,floor)
                evidence.append(dict(wallId=wid,innerRing=i,sourceObjects=[dict(id=j,path=objects[j]['path'],bounds=objects[j]['boundsMeters']) for j in ids],floor=floor,top=top))
            pure=wid in {'p1-stroke-2','p1-stroke-13','p1-stroke-16','p3-stroke-0'}
            if pure:
                tallest=max(parts,key=lambda p:p['maximumSourceZ'])
                parts.append(dict(id='remaining-shared-ink',mode='source-height',remainder=True,
                    floorElevationMeters=tallest['floorElevationMeters'],maximumSourceZ=tallest['maximumSourceZ'],
                    selectedSourceObjects=tallest['selectedSourceObjects'],reason='Remaining ink belongs to the taller of the represented cover assemblies.'))
            else:parts.append(dict(id='structural',mode='solid',remainder=True,floorElevationMeters=c['floorElevationMeters'],reason='Unchanged enclosing structural wall and shared wall joints.'))
            decision['parts']=parts
        if wid=='p2-stroke-0':
            decision.update(mode='source-height',floorElevationMeters=1.,maximumSourceZ=2.,selectedSourceObjects=[5683],reason='B Main platform edge is one metre above its lower floor. Standing eye clears it; no ramp triangles become blockers.')
        if wid in {'p2-stroke-4','p2-stroke-6','p2-stroke-7'}:
            ids=[{'p2-stroke-4':2086,'p2-stroke-6':2085,'p2-stroke-7':2084}[wid]]
            decision.update(mode='source-height',floorElevationMeters=2.,maximumSourceZ=max(objects[i]['boundsMeters'][1][2] for i in ids),selectedSourceObjects=ids,
                reason='Authored spawn bench. Excluded adjacent boundary wall from this low seat assembly.')
        if wid=='p2-stroke-9':
            domain=shapely.Polygon([[256.072,171.567],[259.948,171.567],[259.948,174.604],[256.201,174.604]])
            decision['parts']=[dict(id='crate',mode='source-height',clipBox=[255.5,171.2,260.198,174.854],floorElevationMeters=2.,maximumSourceZ=4.,selectedSourceObjects=[5019],reason='Separate small crate, not the attached tall gable return.'),
                dict(id='return',mode='solid',remainder=True,floorElevationMeters=2.,reason='Actual tall gable return retains full structural blockage.')]
            add_support(wid+'-crate-top','Mid small crate',domain,[5019],2.)
        walls.append(decision)
    output=REV/'summit-svg-height-decisions-v1';output.mkdir(exist_ok=True)
    result=dict(map='summit',walls=walls,supports=supports,sourceReview=evidence,
        reviewEvidence='Root inspected all five source correspondence sheets, each authored small inner ring and matched named actual geometry; separate caps included.',
        limitations=['Conservative structural compounds retain cosmetic openings as solid. These are source-reviewed decisions, not every live-game sightline certified.',
            'Final cone cases, primary ground checks and performance acceptance remain required.'])
    (output/'summit.json').write_text(json.dumps(result,indent=2,allow_nan=False)+'\n')
    print(json.dumps(dict(walls=len(walls),supports=len(supports),reviewedPropRings=len(evidence))))


if __name__=='__main__':main()

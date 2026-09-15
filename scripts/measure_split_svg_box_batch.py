"""Measure two previously associated Split SVG covers without changing models."""
import hashlib,json,math
from pathlib import Path
import xml.etree.ElementTree as ET
import numpy as np
import shapely
from svgpathtools import parse_path

ROOT=Path('E:/IcarusWorldAudit/2026-09-06');REV=ROOT/'tactical-visibility-revision'
OUT=REV/'split-svg-box-height-batch-v1'

def sha(p):return hashlib.sha256(Path(p).read_bytes()).hexdigest()
def stamp(p):return dict(path=str(p),sha256=sha(p))
def write(p,v):p.write_text(json.dumps(v,indent=2,allow_nan=False)+'\n')


def main():
    OUT.mkdir(exist_ok=False)
    gp=ROOT/'supplemented-v2/world/split/geometry.npz';mp=gp.with_suffix('.json')
    data=np.load(gp);points,faces=data['points'],data['faces'];meta=json.loads(mp.read_text())
    cache={}
    def object_triangles(oid):
        if oid not in cache:
            o=meta['objects'][oid];ids=np.arange(o['firstFace'],o['firstFace']+o['faceCount']);cache[oid]=(ids,points[faces[ids]].astype(float))
        return cache[oid]
    def hits_at(xy,oids):
        hits=[];xy=np.array(xy)
        for oid in oids:
            ids,tri=object_triangles(oid)
            for fid,t in zip(ids,tri):
                try:w=np.linalg.solve(np.column_stack((t[1,:2]-t[0,:2],t[2,:2]-t[0,:2])),xy-t[0,:2])
                except np.linalg.LinAlgError:continue
                bary=np.r_[1-w.sum(),w]
                if bary.min()>=-1e-9:
                    hits.append(dict(object=oid,rawFace=int(fid),z=float(bary@t[:,2]),barycentrics=bary.tolist()))
        return sorted(hits,key=lambda h:h['z'])
    models={side:json.loads((REV/f'split-svg-semantic-prototype-v2/split-{side}.json').read_text()) for side in ['attack','defense']}
    svg_paths={side:Path('assets/maps')/('split_map.svg' if side=='attack' else 'split_map_defense.svg') for side in models}
    elements={side:list(ET.parse(path).getroot()) for side,path in svg_paths.items()}
    association_files=[REV/'split-component8-source-review-v3/full-source-context.npz',
        REV/'split-generator-connected-profile-proposal-v4/independent-cubic-cover-contact-review.json',
        REV/'split-generator-connected-profile-proposal-v4/original-height-regression-fixtures.json']
    sources=[stamp(p) for p in association_files]
    configs=[dict(id='b-north-box6694',objects=[6694],ground=6713,center=[-19.99,63.51],
        groundSamples=[[-19.99,65.1],[-21.6,63.51],[-18.4,63.51]],expectedGround=4.,subpath=2,
        walls=dict(attack=['p13-unknown-1'],defense=['p13-unknown-2']),
        expectedSvgBounds=dict(attack=[56.3212,161.54,63.764,168.983],defense=[402.412,304.017,409.855,311.46])),
      dict(id='b-south-box-stack6692-6693',objects=[6692,6693],ground=6712,center=[-16.5,57.02],
        groundSamples=[[-16.5,55.5],[-18.1,56.5],[-14.9,56.5]],expectedGround=3.,subpath=0,
        walls=dict(attack=['p13-unknown-2'],defense=['p13-unknown-1']),
        expectedSvgBounds=dict(attack=[69.6119,186.527,77.5864,194.501],defense=[388.59,278.499,396.564,286.473]))]
    annotations=[];cases=[];measurements=[]
    for cfg in configs:
        ground=[]
        for xy in cfg['groundSamples']:
            hs=[h for h in hits_at(xy,[cfg['ground']]) if abs(h['z']-cfg['expectedGround'])<.01]
            assert len(hs)==1
            ground.append(dict(nativeXY=xy,**hs[0]))
        floor=ground[0]['z'];ground_spread=max(g['z'] for g in ground)-min(g['z'] for g in ground)
        assert ground_spread<1e-5
        center_hits=hits_at(cfg['center'],cfg['objects']);selected=center_hits[-1]
        assert selected['object']==cfg['objects'][-1]
        complete=np.concatenate([object_triangles(oid)[1] for oid in cfg['objects']]);wall_top=float(complete[:,:,2].max())
        top_samples=[]
        for offset in [[0,0],[-.5,-.5],[-.5,.5],[.5,-.5],[.5,.5]]:
            xy=np.array(cfg['center'])+offset;hs=hits_at(xy,cfg['objects']);assert hs
            top_samples.append(dict(nativeXY=xy.tolist(),selectedTop=hs[-1]))
        evidence=dict(sourceObjects=[dict(index=oid,**meta['objects'][oid]) for oid in cfg['objects']],
            sourceGeometry=stamp(gp),sourceMetadata=stamp(mp),priorAssociations=sources,
            adjacentGroundObject=cfg['ground'],adjacentGroundSamples=ground,adjacentGroundSpreadMeters=ground_spread,
            localFloorZ=floor,centerNativeXY=cfg['center'],centerSourceIntersections=center_hits,selectedCenterTop=selected,
            topSamples=top_samples,maximumOriginalWallZ=wall_top,wallTopAboveFloorMeters=wall_top-floor,
            supportHeightAboveFloorMeters=selected['z']-floor,
            maximumWallTopAboveSelectedCenterMeters=wall_top-selected['z'],
            interpretation='Represented solid cover remains solid from tactical ground to its measured top; no cosmetic asset gap becomes an opening.',
            gameplayReview='Existing source contacts establish represented box identity. Physical access onto the top has not been live-game tested; on-top poses test selected support semantics.')
        if len(cfg['objects'])>1:
            lower_top=max(h['z'] for h in center_hits if h['object']==cfg['objects'][0]);upper_min=float(object_triangles(cfg['objects'][1])[1][:,:,2].min())
            evidence['coveredLowerSurface']=dict(object=cfg['objects'][0],centerTopZ=lower_top,upperObject=cfg['objects'][1],upperBaseZ=upper_min,
                policy='Lower box top is covered by the upper matched box at this authored footprint. Export only exposed upper support; retain both source layers in evidence.')
        supports={};shape_checks=[]
        for side in ['attack','defense']:
            e=elements[side][13];sub=parse_path(e.get('d')).continuous_subpaths()[cfg['subpath']]
            xy=np.array([[s.start.real,s.start.imag] for s in sub]+[[sub[-1].end.real,sub[-1].end.imag]])
            shape=shapely.Polygon(xy);assert shape.is_valid and shape.area>0
            # Literal per-side subpath coordinates define all support XY.
            actual_bounds=np.r_[xy.min(0),xy.max(0)]
            assert np.max(abs(actual_bounds-np.array(cfg['expectedSvgBounds'][side])))<.001
            wall=next(w for w in models[side]['walls'] if w['id']==cfg['walls'][side][0]);assert wall['sourcePathIndex']==13
            painted=shapely.Polygon(np.array(wall['rings'][0]).reshape(-1,2),[np.array(r).reshape(-1,2) for r in wall['rings'][1:]])
            expected_ink=shapely.LineString(xy).buffer(.5,cap_style=2,join_style=2,mitre_limit=4)
            difference=shapely.symmetric_difference(painted,expected_ink).area;assert difference<1e-8
            closed=np.vstack((xy,xy[0]));supports[side]=dict(id=cfg['id'],rings=[closed.reshape(-1).tolist()],fillRule='evenodd',
                heightAboveFloorMeters=selected['z']-floor,sourcePathIndex=13,sourceSubpathIndex=cfg['subpath'],
                sourceSvg=stamp(svg_paths[side]),selectedSourceSupport=dict(object=selected['object'],rawFace=selected['rawFace'],z=selected['z']))
            shape_checks.append(dict(side=side,wallId=wall['id'],sourcePathIndex=13,sourceSubpathIndex=cfg['subpath'],supportBoundsSvg=actual_bounds.tolist(),
                existingComponentInkSymmetricDifferenceSvg2=difference,existingWallRingsSha256=hashlib.sha256(json.dumps(wall['rings'],separators=(',',':')).encode()).hexdigest()))
            center=np.array(shape.centroid.coords)[0]
            outward=np.array([0.,-1. if cfg['subpath']==2 else 1.])
            if side=='defense':outward=-outward
            ground_pose=center+outward*(shape.bounds[3]-shape.bounds[1]+8.)/2
            for mode,origin,goal in [('ground',ground_pose,center),('top',center,center+outward*20)]:
                direction=goal-origin;row=dict(id=f'{cfg["id"]}-{mode}-{side}',side=side,originSvg=origin.tolist(),
                    directionRadians=float(math.atan2(direction[1],direction[0])),rangeSvg=80.,apertureRadians=math.radians(103),
                    description=f'{cfg["id"]}: standing beside the solid cover.' if mode=='ground' else f'{cfg["id"]}: standing on its measured exposed top.',
                    sourceEvidence=dict(annotation=cfg['id'],localFloorZ=floor,supportHeightAboveFloorMeters=selected['z']-floor if mode=='top' else 0.,
                        gameplayAccess='Diagnostic selected support; no live-game access claim.'))
                if mode=='top':row['supportId']=cfg['id']
                cases.append(row)
        evidence['svgAssociationChecks']=shape_checks
        annotation=dict(id=cfg['id'],wallsBySide=cfg['walls'],bands=[[0,wall_top-floor]],evidence=evidence,supportsBySide=supports)
        annotations.append(annotation);measurements.append(dict(id=cfg['id'],sourceObjects=cfg['objects'],floorZ=floor,wallTopAboveFloorMeters=wall_top-floor,
            supportHeightAboveFloorMeters=selected['z']-floor,maximumAdjacentGroundSpreadMeters=ground_spread,shapeChecks=shape_checks))
    output=OUT/'annotations.json';write(output,dict(version=1,coordinateSpace='svg',verticalSpace='meters-above-local-floor',annotations=annotations,reviewCases=cases,
        policy='Review-only additions. Current models, rejected vent opening policy, SVG artwork and runtime geometry remain unchanged.'))
    report=dict(annotations=stamp(output),builder=stamp(Path(__file__)),measurements=measurements,sourceObjects=3,representedCovers=2,reviewCases=len(cases),
        currentModelInputs=[stamp(REV/f'split-svg-semantic-prototype-v2/split-{side}.json') for side in ['attack','defense']],
        sourceAssociationInventory=[dict(candidate='north6694',decision='selected',basis='Existing three authored cover-side associations and original full-scene source first contact.'),
            dict(candidate='south6692/6693 stack',decision='selected',basis='Existing authored cover-side associations and separate lower/upper source first contacts.'),
            dict(candidate='third distinct cover',decision='not added',basis='No additional equally clear reviewed association needed for this bounded batch.')],
        productionMutation=False,limitations=['No live-game climb/access validation.','Adjacent ground reference is local to each represented cover.','Unrelated unknown wall heights remain unknown.'],
        next='Root reviews and integrates these two annotations, preserving existing rings and vent policy, then renders the eight beside/on-top controls.')
    write(OUT/'review.json',report);print(json.dumps(dict(output=str(output),measurements=measurements,reviewCases=len(cases)),indent=2))


if __name__=='__main__':main()

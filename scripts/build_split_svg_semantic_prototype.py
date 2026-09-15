"""Export literal Split SVG ink with a bounded set of source-height annotations."""
import gzip, hashlib, json, math, re
from pathlib import Path
import xml.etree.ElementTree as ET
import numpy as np
import shapely
from svgpathtools import parse_path
from tactical_alignment_receiver import flatten

ROOT=Path('E:/IcarusWorldAudit/2026-09-06');REV=ROOT/'tactical-visibility-revision'
OUT=REV/'split-svg-semantic-prototype-v2'
ERROR=.0001

def sha(path):return hashlib.sha256(Path(path).read_bytes()).hexdigest()
def stamp(path):return dict(path=str(path),sha256=sha(path))
def dump(path,value):
    text=json.dumps(value,separators=(',',':'),allow_nan=False)+'\n'
    if path.exists():
        assert path.read_text()==text,('Existing artifact differs',path)
    else:path.write_text(text)
def rings(poly):return [np.array(r.coords).reshape(-1).tolist() for r in [poly.exterior,*poly.interiors]]
def parts(geom):return sorted([p for p in shapely.get_parts(geom) if isinstance(p,shapely.Polygon) and p.area>0],key=lambda p:p.bounds)

def contours(element):
    tag=element.tag.split('}')[-1]
    if tag=='circle':
        radius=float(element.get('r'));center=complex(float(element.get('cx')),float(element.get('cy')))
        count=max(32,math.ceil(math.pi/math.acos(1-ERROR/radius)))
        points=[center+radius*complex(math.cos(t),math.sin(t)) for t in np.linspace(0,2*math.pi,count+1)]
        return [(np.array([[p.real,p.imag] for p in points]),True)]
    if tag!='path':raise ValueError(tag)
    result=[]
    for sub in parse_path(element.get('d')).continuous_subpaths():
        points=[]
        for segment in sub:points.extend(flatten(segment,ERROR)[:-1])
        points.append(sub[-1].end)
        result.append((np.array([[p.real,p.imag] for p in points]),sub.isclosed()))
    return result

def filled(element):
    paths=[]
    for points,_ in contours(element):
        if not np.array_equal(points[0],points[-1]):points=np.vstack((points,points[0]))
        paths.append(points)
    polygons=list(shapely.polygonize(shapely.get_parts(shapely.union_all([shapely.LineString(p) for p in paths]))).geoms)
    starts=np.concatenate([p[:-1] for p in paths]);ends=np.concatenate([p[1:] for p in paths]);accepted=[]
    for polygon in polygons:
        point=np.array(polygon.representative_point().coords)[0]
        cross=(ends[:,0]-starts[:,0])*(point[1]-starts[:,1])-(ends[:,1]-starts[:,1])*(point[0]-starts[:,0])
        winding=int(((starts[:,1]<=point[1])&(ends[:,1]>point[1])&(cross>0)).sum()-((starts[:,1]>point[1])&(ends[:,1]<=point[1])&(cross<0)).sum())
        if (abs(winding)%2==1) if element.get('fill-rule')=='evenodd' else winding!=0:accepted.append(polygon)
    return shapely.union_all(accepted)

def footprint(element):
    if element.get('fill','').lower()=='#b27c40':return filled(element)
    width=float(element.get('stroke-width','1'));cap=element.get('stroke-linecap','butt');join=element.get('stroke-linejoin','miter')
    assert cap in ['butt','round','square'] and join in ['miter','round','bevel']
    # Arc chord error is bounded separately from original-path curve flattening.
    q=max(8,math.ceil(math.pi/(4*math.acos(1-min(ERROR/(width/2),.999)))))
    return shapely.union_all([shapely.LineString(p).buffer(width/2,cap_style={'round':1,'butt':2,'square':3}[cap],
        join_style={'round':1,'miter':2,'bevel':3}[join],mitre_limit=float(element.get('stroke-miterlimit','4')),quad_segs=q) for p,_ in contours(element)])

def raw_support_evidence(points,faces,meta):
    box=meta['objects'][5803];ids=np.arange(box['firstFace'],box['firstFace']+box['faceCount']);tri=points[faces[ids]].astype(float)
    def heights_at(xy,indices):
        result=[]
        for i in indices:
            t=points[faces[i]].astype(float)
            try:w=np.linalg.solve(np.column_stack((t[1,:2]-t[0,:2],t[2,:2]-t[0,:2])),np.array(xy)-t[0,:2])
            except np.linalg.LinAlgError:continue
            b=np.r_[1-w.sum(),w]
            if b.min()>=-1e-9:result.append(dict(rawFace=int(i),z=float(b@t[:,2])))
        return result
    center=heights_at([71.99,70],ids);assert len(center)==1
    ground_obj=meta['objects'][5862];ground_ids=np.arange(ground_obj['firstFace'],ground_obj['firstFace']+ground_obj['faceCount'])
    ground=[]
    for xy in [[71.99,68.5],[70.5,70],[73.5,70]]:
        hits=[h for h in heights_at(xy,ground_ids) if abs(h['z'])<.3];assert len(hits)==1
        ground.append(dict(nativeXY=xy,**hits[0]))
    floor=ground[0]['z'];top=float(tri[:,:,2].max());center_top=center[0]['z']
    top_ids=ids[(np.ptp(tri[:,:,2],axis=1)<1e-5)&(tri[:,:,2].mean(1)>3.97)].tolist()
    return dict(object=5803,sourceObject=box,centerNativeXY=[71.99,70],centerTop=center[0],rimTopZ=top,rimTopRawFaces=top_ids,
        adjacentGroundObject=5862,adjacentGroundSamples=ground,localFloorZ=floor,
        centerHeightAboveFloor=center_top-floor,wallTopAboveFloor=top-floor,rimVariationMeters=top-center_top,
        supportPolicy='Use the center top plane over the authored box footprint. The modeled rim is1.94cm higher; no new XY rim absent from the SVG is added.' )

def opening_evidence(points,faces,meta,projection):
    # Existing reviewed174 source association. XY is used only for semantic matching.
    box=[256.5,196.,262.8,197.1];floor=2.6;records=[]
    def clip(poly,axis,bound,sign):
        result=[]
        for a,b in zip(poly,poly[1:]+poly[:1]):
            av=(a[axis]-bound)*sign;bv=(b[axis]-bound)*sign
            if av>=0:result.append(a)
            if (av>=0)!=(bv>=0):result.append(a+(b-a)*av/(av-bv))
        return result
    for oid in [7795,7796,4773]:
        obj=meta['objects'][oid];ids=np.arange(obj['firstFace'],obj['firstFace']+obj['faceCount']);tri=points[faces[ids]].astype(float)
        tri[:,:,:2]=tri[:,:,:2]@projection[:,:2].T+projection[:,2]
        for fid,t in zip(ids,tri):
            if np.any(t[:,:2].max(0)<box[:2]) or np.any(t[:,:2].min(0)>box[2:]):continue
            poly=list(t)
            for axis,bound,sign in [(0,box[0],1),(0,box[2],-1),(1,box[1],1),(1,box[3],-1)]:
                if not poly:break
                poly=clip(poly,axis,bound,sign)
            if len(poly)<3:continue
            z=np.array(poly)[:,2]
            if z.max()<=floor:continue
            records.append(dict(object=oid,rawFace=int(fid),minimumZ=float(z.min()),maximumZ=float(z.max())))
    lower=min(r['minimumZ'] for r in records);upper=max(r['maximumZ'] for r in records);assert lower>6.3
    source_ends=[255.80903050904556,263.62827106121273];authored_ends=[256.214,263.657]
    endpoints=np.interp([box[0],box[2]],source_ends,authored_ends).tolist()
    return dict(sourceObjects=[7795,7796,4773],sourceMatchBoxSvg=box,sourceFloorZ=floor,sourceRecords=records,
        sourceMinimumOverheadZ=lower,sourceMaximumOverheadZ=upper,heightBandAboveFloor=[lower-floor,upper-floor],
        authoredXInterval=endpoints,authoredY=196.096,
        policy='The central reviewed opening has no source blocker below the overhead envelope. Higher detail is conservatively represented by its full envelope; end joints remain unknown opaque. This is a bounded first-pass height annotation, not a full vertical silhouette.')

def main():
    OUT.mkdir(exist_ok=True)
    assert not (OUT/'split-attack.json').exists(), 'Preserve previous model exports.'
    gp=ROOT/'supplemented-v2/world/split/geometry.npz';mp=gp.with_suffix('.json');raw=np.load(gp);points,faces=raw['points'],raw['faces'];meta=json.loads(mp.read_text())
    projection=np.array(json.loads((ROOT/'tactical-alignment-sides-v1/split.json').read_text())['nativeToAttackSvg'])
    support=raw_support_evidence(points,faces,meta);opening=opening_evidence(points,faces,meta,projection)
    dump(OUT/'source-height-evidence.json',dict(geometry=stamp(gp),metadata=stamp(mp),box=support,opening=opening))
    mirror=np.array([466.1762,473.]);models={};reports=[]
    for side,name in [('attack','split_map.svg'),('defense','split_map_defense.svg')]:
        path=Path('assets/maps')/name;root=ET.parse(path).getroot()
        elements=list(root);walls=[];paint=[];receiver=[];all_ink=[];known_main_area=0
        for index,e in enumerate(elements):
            if e.get('fill','').lower()=='#271406':
                receiver.extend([dict(rings=rings(p),fillRule='evenodd') for p in parts(filled(e))])
            if e.get('fill','').lower()!='#b27c40' and e.get('stroke','').lower()!='#b27c40':continue
            assert 'style' not in e.attrib,'Painted wall style requires explicit expansion.'
            if 'transform' in e.attrib:
                rotation=re.fullmatch(r'rotate\(([-\d.]+) ([-\d.]+) ([-\d.]+)\)',e.get('transform'))
                assert e.tag.endswith('circle') and rotation and float(rotation[2])==float(e.get('cx')) and float(rotation[3])==float(e.get('cy')), 'Unsupported painted transform'
                # Rotating a circle about its own literal center preserves its footprint.
            geom=footprint(e);all_ink.append(geom)
            paint.append(dict(sourcePathIndex=index,element=e.tag.split('}')[-1],attributes=e.attrib,
                footprintKind='literal-filled-outline' if e.get('fill','').lower()=='#b27c40' else 'expanded-authored-stroke',
                resolvedStrokeWidth=float(e.get('stroke-width','1')) if e.get('stroke') else None,
                resolvedLineJoin=e.get('stroke-linejoin','miter') if e.get('stroke') else None,
                resolvedLineCap=e.get('stroke-linecap','butt') if e.get('stroke') else None,
                resolvedMiterLimit=float(e.get('stroke-miterlimit','4')) if e.get('stroke') else None))
            if index==1:
                x0,x1=opening['authoredXInterval'];y=opening['authoredY'];clipbox=np.array([x0,y-.5,x1,y+.5])
                if side=='defense':clipbox=np.r_[mirror-clipbox[2:],mirror-clipbox[:2]]
                known=shapely.intersection(geom,shapely.box(*clipbox));geom=shapely.difference(geom,known);known_main_area=known.area
                for j,p in enumerate(parts(known)):
                    walls.append(dict(id=f'vent174-opening-{j}',sourcePathIndex=index,rings=rings(p),fillRule='evenodd',
                        bands=[[0,None]],unknownHeight=False,heightEvidence='opening',heightModel='gameplay-solid',
                        gameplayReview=dict(decision='block',reason='Dara identified this asset gap as nonfunctional for gameplay. It must not create a tactical sightline.',
                            source='User annotated vent-opening preview, September 6, 2026',
                            rejectedAssetInference='conservative-overhead-envelope')))
            if index==6:
                # This exact authored U-shaped subpath is the previously reviewed5803 cover.
                sub=contours(e)[1][0];cover=shapely.LineString(sub).buffer(.5,cap_style=2,join_style=2,mitre_limit=4)
                known=shapely.intersection(geom,cover);geom=shapely.difference(geom,known)
                for j,p in enumerate(parts(known)):
                    walls.append(dict(id=f'box5803-wall-{j}',sourcePathIndex=index,rings=rings(p),fillRule='evenodd',
                        bands=[[0,support['wallTopAboveFloor']]],unknownHeight=False,heightEvidence='box',supportId='box5803'))
                box_poly=shapely.Polygon(sub)
                support_record=dict(id='box5803',rings=rings(box_poly),fillRule='evenodd',heightAboveFloorMeters=support['centerHeightAboveFloor'],
                    sourceObject=5803,heightEvidence='box',rimVariationMeters=support['rimVariationMeters'])
            for j,p in enumerate(parts(geom)):
                walls.append(dict(id=f'p{index}-unknown-{j}',sourcePathIndex=index,rings=rings(p),fillRule='evenodd',bands=[],unknownHeight=True))
        ink=shapely.union_all(all_ink);exported=shapely.union_all([shapely.Polygon(np.array(w['rings'][0]).reshape(-1,2),[np.array(r).reshape(-1,2) for r in w['rings'][1:]]) for w in walls])
        area_error=shapely.symmetric_difference(ink,exported).area;assert area_error<1e-7
        model=dict(version=1,map='split',side=side,coordinateSpace='svg',verticalSpace='meters-above-local-floor',viewBox=[0,0,467,473],
            defaultCameraHeightMeters=1.75,cellSizeSvg=16,curveFlatteningErrorSvg=ERROR,strokeArcErrorSvg=ERROR,
            sourceSvg=stamp(path),paintSources=paint,walls=walls,supports=[support_record],receiver=receiver,
            sourceHeightEvidence=dict(file='source-height-evidence.json',sha256=sha(OUT/'source-height-evidence.json')),
            limitations=['Most wall heights remain unknown and opaque.','Vent174 is deliberately solid by gameplay review; measured overhead geometry remains reference evidence only.',
                'Box support uses its measured center plane; modeled rim variation is recorded.','Connected ground is tactically flat; no source-mesh XY edges are exported.'])
        output=OUT/f'split-{side}.json';dump(output,model);models[side]=model
        reports.append(dict(side=side,file=str(output),sha256=sha(output),bytes=output.stat().st_size,gzipBytes=len(gzip.compress(output.read_bytes(),mtime=0)),
            wallComponents=len(walls),knownHeightComponents=sum(not w['unknownHeight'] for w in walls),unknownHeightComponents=sum(w['unknownHeight'] for w in walls),
            knownMainOutlineAreaSvg2=known_main_area,totalMainOutlineAreaSvg2=all_ink[0].area,paintedFootprintSymmetricDifferenceSvg2=area_error))
    cases=[]
    def pose(identifier,origin,goal,description,evidence,support_id=None):
        delta=np.array(goal)-origin;row=dict(id=identifier,side='attack',originSvg=origin,directionRadians=float(math.atan2(delta[1],delta[0])),
            rangeSvg=100.,apertureRadians=math.radians(103),description=description,sourceEvidence=evidence)
        if support_id:row['supportId']=support_id
        cases.append(row)
    pose('box5803-ground',[421.0195,149.],[421.0195,138.946],'Standing beside the authored box; source wall top blocks the view.',dict(heightEvidence='box'))
    pose('box5803-top',[421.0195,138.946],[421.0195,152.],'Standing on the source-backed center top; the box sides lie below the camera.',dict(heightEvidence='box'),'box5803')
    pose('vent174-opening',[259.8,202.],[259.8,190.],'Nonfunctional asset gap: the authored wall blocks the tactical sightline.',dict(gameplayReview='Dara rejected this gap as a usable gameplay sightline',sourceFloorZ=2.6))
    old=REV/'split-pipe130-profile-region-proposal-v5/regression-fixtures.json';clove=json.loads(old.read_text())['fixtures']
    selected=next(r for r in clove if r['id']=='clove-left-opening-invariant-1');q=selected.get('sourceQuery')
    if q is not None:
        xy=np.array(q[:2])@projection[:,:2].T+projection[:,2];heading=np.array(q[3:5])@projection[:,:2].T
        pose('clove-left-opening',xy.tolist(),(xy+heading).tolist(),'Existing source-clear left doorway control. No extra exported edge is added.',dict(file=str(old),sha256=sha(old),fixture=selected['id']))
    dump(OUT/'review-poses.json',dict(cases=cases,policy='Source-backed box and bounded opening controls. No invented support height or new source-derived wall XY.'))
    review=dict(schema='SVG painted rings plus local-floor-relative height intervals',models=reports,sourceEvidence=stamp(OUT/'source-height-evidence.json'),
        reviewPoses=stamp(OUT/'review-poses.json'),builder=stamp(Path(__file__)),productionMutation=False,
        classifiedScope='Vent174 is gameplay-reviewed solid;5803 has source-backed box walls/support. All other components explicitly unknown opaque.',
        next='Render these exact footprints and source-backed controls in the Dart prototype before adding more source associations.')
    dump(OUT/'review.json',review);print(json.dumps(review,indent=2))


if __name__=='__main__':main()

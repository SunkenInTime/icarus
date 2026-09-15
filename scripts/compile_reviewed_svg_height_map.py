"""Compile reviewed source-height decisions onto unchanged paired SVG ink.

The default refuses pending decisions. --draft writes explicitly unreviewed
models to an external review directory; it never registers or bundles a map.
"""
import argparse
import copy
import gzip
import hashlib
import json
from pathlib import Path

import numpy as np
import shapely
from shapely.affinity import affine_transform

from audit_svg_source_height_associations import ROOT, REV


def polygon(row):
    q=[np.array(r).reshape(-1,2) for r in row['rings']]
    if row.get('fillRule')=='evenodd':
        result=shapely.Polygon()
        for ring in q:result=result.symmetric_difference(shapely.make_valid(shapely.Polygon(ring)))
        return result
    return shapely.Polygon(q[0],q[1:])


def rings(shape):
    return [np.array(r.coords).reshape(-1).tolist() for r in [shape.exterior,*shape.interiors]]


def assumed_height(decision):
    """A review label cannot turn an unbounded structural guess into evidence."""
    if 'bandsAboveFloor' in decision:
        return any(high is None or not np.isfinite(high)
                   for _, high in decision['bandsAboveFloor'])
    mode = decision.get('mode', decision.get('suggestedMode'))
    if mode == 'source-height':
        top = decision.get('maximumSourceZ')
        return top is None or not np.isfinite(top)
    return mode == 'solid'


def height_record(original, decision, draft):
    mode=decision.get('mode',decision.get('suggestedMode'))
    floor=decision.get('floorElevationMeters')
    if floor is None:
        if not draft:raise ValueError(('Missing source floor',original['id']))
        floor=0.
    assumption = assumed_height(decision)
    if assumption and not draft:
        raise ValueError(('Assumed structural height is not reviewed source data', original['id']))
    if decision.get('reviewStatus')!='reviewed' or assumption:bands=[];unknown=True
    else:
        unknown=False
        if 'bandsAboveFloor' in decision:bands=decision['bandsAboveFloor']
        elif mode=='solid':bands=[[0,None]]
        elif mode=='connected-ground':bands=[]
        elif mode=='source-height':
            top=decision['maximumSourceZ']
            if top<=floor:raise ValueError(('Nonpositive wall height',original['id'],top,floor))
            bands=[[0,top-floor]]
        else:raise ValueError(('Unknown decision mode',original['id'],mode))
    wall=copy.deepcopy(original)
    wall.update(floorElevationMeters=floor,bands=bands,unknownHeight=unknown,heightEvidence=decision)
    return wall


def compile_map(name, decisions_path, output, draft=False):
    decisions=json.loads(decisions_path.read_text())
    if decisions['map'] != name:
        raise ValueError('Decision map mismatch')
    footprint={s:json.loads((REV/f'all-map-svg-footprints-v1/{name}-{s}.json').read_text())
               for s in ('attack','defense')}
    decision_rows=list(decisions['walls'].values()) if isinstance(decisions['walls'],dict) else decisions['walls']
    by_id={r['wallId']:r for r in decision_rows}
    attack=footprint['attack']
    if len(by_id)!=len(decision_rows) or set(by_id)!={w['id'] for w in attack['walls']}:
        raise ValueError('Decisions must cover each authored attack wall exactly once')
    pending=[r['wallId'] for r in by_id.values()
             if r['reviewStatus']!='reviewed' or any(assumed_height(p)
                 for p in (r.get('parts') or [r]))]
    if pending and not draft:
        raise ValueError(f'{len(pending)} source associations still require review')
    for original in attack['walls']:
        d=by_id[original['id']]
        if d.get('parts'):
            remaining=polygon(original);pieces=[]
            for p in d['parts']:
                if p.get('remainder'):domain=remaining
                elif 'clipBox' in p:domain=shapely.box(*p['clipBox'])
                elif 'clipRings' in p:domain=polygon(dict(rings=p['clipRings'],fillRule=p.get('fillRule','evenodd')))
                else:domain=polygon(p)
                piece=remaining.intersection(domain);pieces.append(piece)
                remaining=remaining.difference(piece)
            union=shapely.union_all(pieces)
            if polygon(original).symmetric_difference(union).area>1e-7:
                raise ValueError(('Parts do not preserve literal parent ink',original['id']))
            if not draft and any(p.get('reviewStatus',d['reviewStatus'])!='reviewed' for p in d['parts']):
                raise ValueError(('Unreviewed height partition',original['id']))
    registration=json.loads((ROOT/f'tactical-alignment-sides-v1/{name}.json').read_text())
    matrices={s:np.array(registration[f'nativeTo{s.title()}Svg']) for s in footprint}
    a,b=matrices['attack'],matrices['defense']
    linear=b[:,:2]@np.linalg.inv(a[:,:2]);offset=b[:,2]-linear@a[:,2]
    coefficients=[*linear[0],*linear[1],*offset]
    defense=footprint['defense']['walls']
    defense_shapes=[polygon(w) for w in defense]
    mates={};used=set();pair_errors=[]
    for wall in attack['walls']:
        reflected=affine_transform(polygon(wall),coefficients)
        candidates=[i for i,w in enumerate(defense)
                    if w['sourcePathIndex']==wall['sourcePathIndex'] and i not in used]
        if not candidates:raise ValueError(('Missing defense counterpart',wall['id']))
        index=min(candidates,key=lambda i:reflected.hausdorff_distance(defense_shapes[i]))
        error=reflected.hausdorff_distance(defense_shapes[index])
        overlap=reflected.intersection(defense_shapes[index]).area/reflected.union(defense_shapes[index]).area
        # Paired artwork can contain tiny internal stroke differences. A unique
        # near-identical painted footprint may share height evidence while each
        # side keeps its own literal geometry. Never snap one side to the other.
        alternative=min((reflected.hausdorff_distance(defense_shapes[i]) for i in candidates if i!=index),default=float('inf'))
        if error>.01 and not (overlap>.995 and error<.6 and alternative>error+2):
            raise ValueError(('Ambiguous paired artwork',wall['id'],error,overlap))
        used.add(index);mates[defense[index]['id']]=wall['id'];pair_errors.append(error)
    if len(used)!=len(defense):raise ValueError('Unmatched defense walls')
    ground_path=Path(decisions['groundModel']) if decisions.get('groundModel') else REV/f'global-ground-v1/{name}.tactical-ground.json.gz'
    ground=json.loads(gzip.decompress(ground_path.read_bytes()))
    if decisions.get('groundModel') and not draft and decisions.get('groundReviewStatus')!='reviewed':
        raise ValueError('Replacement primary ground requires explicit review')
    vertices=np.array(ground['vertices']).reshape(-1,3)
    report=[];output.mkdir(parents=True,exist_ok=True)
    for side,base in footprint.items():
        projected=vertices.copy();matrix=matrices[side]
        projected[:,:2]=vertices[:,:2]@matrix[:,:2].T+matrix[:,2]
        # Resolve touching/overlapping floor fills offline. Skia Path.combine
        # can reject valid boundary-touching subpaths; a baked union also avoids
        # repeating boolean geometry during first paint.
        receiver_union=shapely.union_all([polygon(row) for row in base['receivers']])
        receiver_parts=[p for p in shapely.get_parts(receiver_union) if p.geom_type=='Polygon' and p.area>0]
        receiver_record=dict(rings=[ring for p in receiver_parts for ring in rings(p)],fillRule='evenodd')
        if polygon(receiver_record).symmetric_difference(receiver_union).area>1e-7:
            raise ValueError('Receiver union encoding changed the floor footprint')
        model=dict(version=2,map=name,side=side,coordinateSpace='svg',
                   verticalSpace='meters-source-elevation',viewBox=base['viewBox'],
                   defaultCameraHeightMeters=1.75,sourceSvg=base['sourceSvg'],
                   ground=dict(vertices=projected.reshape(-1).tolist(),triangles=ground['triangles']),
                   receiver=[receiver_record],walls=[],supports=[],
                   reviewStatus='draft' if pending else 'reviewed',pendingWallIds=pending,
                   sourceDecisionsSha256=hashlib.sha256(decisions_path.read_bytes()).hexdigest())
        for original in base['walls']:
            key=original['id'] if side=='attack' else mates[original['id']]
            decision=by_id[key]
            if not decision.get('parts'):
                model['walls'].append(height_record(original,decision,draft));continue
            remaining=polygon(original)
            for raw_part in decision['parts']:
                part={'reviewStatus':decision['reviewStatus'],**raw_part}
                if part.get('remainder'):domain=remaining
                elif 'clipBox' in part:domain=shapely.box(*part['clipBox'])
                elif 'clipRings' in part:domain=polygon(dict(rings=part['clipRings'],fillRule=part.get('fillRule','evenodd')))
                else:domain=polygon(part)
                if side=='defense':domain=affine_transform(domain,coefficients)
                if part.get('remainder'):domain=remaining
                clipped=remaining.intersection(domain)
                for i,p in enumerate(shapely.get_parts(clipped)):
                    if p.geom_type!='Polygon' or p.area<1e-12:continue
                    record=dict(id=f'{original["id"]}-{part["id"]}-{i}',rings=rings(p),fillRule='evenodd',sourcePathIndex=original['sourcePathIndex'])
                    model['walls'].append(height_record(record,part,draft))
                remaining=remaining.difference(clipped)
            if remaining.area>1e-7:raise ValueError(('Side partition leaves unassigned ink',side,key,remaining.area))
        wall_shapes=[polygon(w) for w in model['walls']]
        support_domain_review=[]
        for raw in decisions.get('supports',[]):
            if raw.get('reviewStatus')!='reviewed':continue
            if raw.get('automaticStandingAllowed') and not raw.get('standingGameplayEvidence'):
                raise ValueError(('Automatic standing requires gameplay evidence', raw['id']))
            support=copy.deepcopy(raw)
            if side=='defense':
                support['rings']=[(np.array(r).reshape(-1,2)@linear.T+offset).reshape(-1).tolist() for r in raw['rings']]
            source_domain=polygon(support)
            eye=support['surfaceElevationMeters']+model['defaultCameraHeightMeters']
            active=[];overlap=[]
            for wall,shape in zip(model['walls'],wall_shapes):
                height=eye-wall['floorElevationMeters']
                blocked=any((lo==0 or lo<=height) and (hi is None or height<=hi) for lo,hi in wall['bands'])
                if not blocked:continue
                area=source_domain.intersection(shape).area
                if area>1e-10:
                    active.append(shape);overlap.append(dict(wallId=wall['id'],areaSvg=area))
            allowed=source_domain.intersection(receiver_union).difference(shapely.union_all(active))
            pieces=[]
            for p in shapely.get_parts(allowed):
                if p.geom_type!='Polygon' or p.area<=1e-10:continue
                pieces.append(shapely.Polygon(p.exterior,[ring for ring in p.interiors if shapely.Polygon(ring).area>1e-10]))
            if not pieces:
                raise ValueError(('Support has no valid SVG standing domain',side,support['id'],overlap))
            support['rings']=[ring for p in pieces for ring in rings(p)]
            support['fillRule']='evenodd'
            support_domain_review.append(dict(id=support['id'],sourceAreaSvg=source_domain.area,
                outsideReceiverAreaSvg=source_domain.difference(receiver_union).area,
                activeWallOverlaps=overlap,emittedAreaSvg=sum(p.area for p in pieces)))
            model['supports'].append(support)
        model['supportDomainReview']=support_domain_review
        encoded=json.dumps(model,separators=(',',':'),allow_nan=False).encode()
        target=output/f'{name}-{side}.json';target.write_bytes(encoded)
        report.append(dict(side=side,output=str(target),walls=len(model['walls']),supports=len(model['supports']),
                           pending=len(pending),jsonBytes=len(encoded),gzipBytes=len(gzip.compress(encoded,mtime=0))))
    (output/f'{name}-compile-report.json').write_text(json.dumps(dict(map=name,
        maximumPairDistanceSvg=max(pair_errors),sides=report,registeredInApp=False),indent=2)+'\n')
    return report


if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--map',required=True)
    p.add_argument('--decisions',type=Path,required=True);p.add_argument('--out',type=Path,required=True)
    p.add_argument('--draft',action='store_true');a=p.parse_args()
    print(json.dumps(compile_map(a.map,a.decisions,a.out,a.draft)))

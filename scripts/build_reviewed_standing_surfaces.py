"""Add locally reviewed standing faces without changing walls or saved levels."""
from collections import Counter,defaultdict
import gzip
import hashlib
import json
from pathlib import Path
import numpy as np
import shapely
from shapely.affinity import affine_transform
from audit_all_map_gameplay_levels import ROOT,MAPS,read,planes
from build_all_map_gameplay_supports import plane_region
from build_all_physical_standing_surfaces import affine,sha,transformed_plane,selected_ground_domains
from compile_reviewed_svg_height_map import polygon,rings
from gameplay_standing_volumes import StandingVolumes

OUTPUT=ROOT/'tactical-visibility-revision/all-map-reviewed-standing-v10'
REVIEW=Path(__file__).parent/'data/gameplay-standing-review-2026-09-08.json'


def clean(shape):
    valid=shapely.set_precision(shapely.make_valid(shape),1e-7)
    return shapely.union_all([p for p in shapely.get_parts(valid) if p.geom_type=='Polygon' and p.area>1e-10])


def build(name,review):
    directory=OUTPUT/name;directory.mkdir(parents=True,exist_ok=True)
    for side in ['attack','defense']:
        baseline=directory/f'before-{side}.json.gz'
        if not baseline.exists():baseline.write_bytes(Path(f'assets/maps/{name}_svg_height_{side}.json.gz').read_bytes())
    models={s:read(directory/f'before-{s}.json.gz') for s in ['attack','defense']}
    entry=review['maps'].get(name)
    if not entry:
        for side in models:(directory/f'candidate-{side}.json.gz').write_bytes((directory/f'before-{side}.json.gz').read_bytes())
        return
    geometry_path=ROOT/f'supplemented-v2/world/{name}/geometry.npz'
    alignment_path=ROOT/f'tactical-alignment-sides-v1/{name}.json'
    assert sha(geometry_path)==entry['sourceGeometrySha256']
    assert sha(geometry_path.with_suffix('.json'))==entry['sourceMetadataSha256']
    assert sha(alignment_path)==entry['alignmentSha256']
    geometry=np.load(geometry_path);metadata=read(geometry_path.with_suffix('.json'))['objects']
    matrices={s:np.array(read(alignment_path)[f'nativeTo{s.title()}Svg']) for s in models}
    attack=matrices['attack'];inverse=np.c_[np.linalg.inv(attack[:,:2]),-np.linalg.inv(attack[:,:2])@attack[:,2]]
    receivers={s:shapely.union_all([polygon(r) for r in m['receiver']]) for s,m in models.items()}
    wall_shapes={s:np.array([polygon(w) for w in m['walls']],dtype=object) for s,m in models.items()}
    wall_trees={s:shapely.STRtree(v) for s,v in wall_shapes.items()}
    vertices=np.array(models['attack']['ground']['vertices']).reshape(-1,3)
    ground_tri=vertices[np.array(models['attack']['ground']['triangles']).reshape(-1,3)]
    coverage_shapes=selected_ground_domains(ground_tri);coverage_planes=list(planes(ground_tri))
    for support in models['attack']['supports']:
        if support.get('automaticStandingAllowed'):
            coverage_shapes.append(polygon(support))
            coverage_planes.append(np.array(support.get('surfacePlane') or [0.,0.,support['surfaceElevationMeters']]))
    coverage_tree=shapely.STRtree(coverage_shapes)
    exclusions={r['sourceObject']:polygon(dict(rings=r['nativeRings'],fillRule=r['fillRule'])) for r in entry.get('exclusions',[])}
    samples_by_face=defaultdict(list)
    for row in entry['samples']:samples_by_face[row['sourceFace']].append(row)
    volumes=StandingVolumes(name);body_ids={r['id']:i for i,r in enumerate(volumes.rows)}
    groups=defaultdict(list);evidence=defaultdict(list);physical_evidence={}
    for face,samples in samples_by_face.items():
        row=samples[0];obj=metadata[row['sourceObject']]
        assert obj['path']==row['sourcePath'] and obj['firstFace']<=face<obj['firstFace']+obj['faceCount']
        triangle=geometry['points'][geometry['faces'][face]].astype(float)
        plane=np.linalg.solve(np.c_[triangle[:,:2],np.ones(3)],triangle[:,2])
        for r in samples:assert abs(plane[:2]@r['nativeXY']+plane[2]-r['renderedElevationMeters'])<1e-6
        source_domain=clean(shapely.Polygon(triangle[:,:2]))
        if row['sourceObject'] in exclusions:source_domain=clean(source_domain.difference(exclusions[row['sourceObject']]))
        replaced=[]
        for r in samples:
            physical=r['physicalFloor']
            if physical is None:continue
            index=body_ids[physical['collision']];tri=volumes.triangles[index]
            actual=tri[physical['face']]
            coefficient=np.linalg.solve(np.c_[actual[:,:2],np.ones(3)],actual[:,2])
            assert np.max(abs(coefficient-np.array(physical['plane'])))<1e-7
            assert abs(coefficient[:2]@r['nativeXY']+coefficient[2]-physical['floorMeters'])<1e-6
            coplanar=np.max(abs(tri[:,:,2]-tri[:,:,:2]@coefficient[:2]-coefficient[2]),axis=1)<1e-6
            local=clean(source_domain.intersection(shapely.union_all(shapely.polygons(tri[coplanar,:,:2]))))
            if local.is_empty:continue
            key=('physical',physical['collision'],*np.round(coefficient,10))
            groups[key].append(local);evidence[key].append(dict(sourceFace=face,reviewedSample=r['id']))
            physical_evidence[physical['collision']]=dict(source=volumes.rows[index],
                trianglesSha256=hashlib.sha256(tri.tobytes()).hexdigest())
            replaced.append(local)
        remaining=clean(source_domain.difference(shapely.union_all(replaced)))
        if not remaining.is_empty:
            key=('gameplay-review',str(row['sourceObject']),*np.round(plane,10))
            groups[key].append(remaining);evidence[key].append(dict(sourceFace=face,reviewedSamples=[r['id'] for r in samples]))
    additions=[];records=[]
    for key,pieces in sorted(groups.items()):
        plane=np.array(key[2:]);domain=clean(shapely.union_all(pieces))
        svg=clean(affine_transform(domain,affine(attack)).intersection(receivers['attack']))
        local=transformed_plane(plane,attack)
        covered=[plane_region(svg.intersection(coverage_shapes[i]),local-coverage_planes[i],-.015,.015)
                 for i in coverage_tree.query(svg,predicate='intersects')]
        svg=clean(svg.difference(shapely.union_all(covered)))
        if svg.is_empty:continue
        # SVG ink retains authority over sightline walls on both map sides.
        for side in models:
            matrix=matrices[side];linear=matrix[:,:2]@inverse[:,:2];shift=matrix[:,2]-linear@attack[:,2]
            side_svg=affine_transform(svg,[*linear[0],*linear[1],*shift])
            blocks=[];side_plane=transformed_plane(plane,matrix)
            for i in wall_trees[side].query(side_svg,predicate='intersects'):
                w=models[side]['walls'][i];assert not w['unknownHeight']
                for lo,hi in w['bands']:
                    low=-np.inf if lo==0 else w['floorElevationMeters']+lo-models[side]['defaultCameraHeightMeters']
                    high=w['floorElevationMeters']+hi-models[side]['defaultCameraHeightMeters']
                    blocks.append(plane_region(wall_shapes[side][i],side_plane,low,high))
            side_svg=clean(side_svg.difference(shapely.union_all(blocks)))
            back=np.linalg.inv(linear)
            svg=clean(svg.intersection(affine_transform(side_svg,[*back[0],*back[1],*(-back@shift)])))
        if svg.is_empty:continue
        sid=f'{name}-reviewed-standing-'+hashlib.sha256(str(key).encode()).hexdigest()[:12]
        encoded=[r for p in shapely.get_parts(svg) if p.geom_type=='Polygon' for r in rings(p)]
        additions.append((sid,plane,encoded))
        records.append(dict(supportId=sid,eligibilityBasis='Dara gameplay review 2026-09-08',
            heightBasis=key[0],sourceIdentity=key[1],nativePlane=plane.tolist(),sourceFaces=evidence[key],
            areaSquareMeters=svg.area/abs(np.linalg.det(attack[:,:2]))))
    for side,model in models.items():
        matrix=matrices[side];linear=matrix[:,:2]@inverse[:,:2];shift=matrix[:,2]-linear@attack[:,2]
        for sid,plane,encoded in additions:
            side_rings=encoded if side=='attack' else [(np.array(r).reshape(-1,2)@linear.T+shift).reshape(-1).tolist() for r in encoded]
            local=transformed_plane(plane,matrix)
            p=polygon(dict(rings=side_rings,fillRule='evenodd')).representative_point()
            z=float(local[:2]@[p.x,p.y]+local[2])
            support=dict(id=sid,label='Platform',rings=side_rings,fillRule='evenodd',floorElevationMeters=0.,
                heightAboveFloorMeters=z,surfaceElevationMeters=z,automaticStandingAllowed=True)
            if np.linalg.norm(local[:2])>1e-9:support['surfacePlane']=local.tolist()
            model['supports'].append(support)
        target=directory/f'candidate-{side}.json.gz'
        target.write_bytes(gzip.compress(json.dumps(model,separators=(',',':'),allow_nan=False).encode(),mtime=0))
    report=dict(map=name,reviewSha256=sha(REVIEW),buildScriptSha256=sha(Path(__file__)),
        sourceReview=entry,physicalEvidence=physical_evidence,records=records,newSupports=len(additions),
        beforeSha256={s:sha(directory/f'before-{s}.json.gz') for s in models},
        candidateSha256={s:sha(directory/f'candidate-{s}.json.gz') for s in models})
    (directory/'reviewed-standing-build.json').write_text(json.dumps(report,indent=2))
    print(name,len(entry['samples']),'reviewed samples,',len(additions),'new surfaces',flush=True)


if __name__=='__main__':
    review=read(REVIEW)
    for name in MAPS:build(name,review)

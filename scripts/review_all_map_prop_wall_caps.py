"""Replace infinite prop outlines with their measured finite assembly heights."""
import gzip
import json
import numpy as np
import shapely
from shapely.affinity import affine_transform
from audit_all_map_gameplay_levels import OUT,ROOT,read
from compile_reviewed_svg_height_map import polygon,rings


SPECS={
    'abyss':{'p8-stroke-0':[([32,188,1000,204],[5644]),(None,[5672,5642])]},
    'ascent':{
        'p2-stroke-1':[(None,[3027,3029,3028])],
        'p2-stroke-2':[(None,[3030,3031])],
        'p2-stroke-5':[(None,[6909])],
        'p2-stroke-10':[(None,[7954])],
        'p2-stroke-11':[(None,[7918])],
        'p2-stroke-12':[(None,[6390])],
        'p2-stroke-13':[(None,[4883,4884])],
        'p2-stroke-15':[(None,[4885,4886])],
        'p2-stroke-16':[(None,[4882])],
        'p2-stroke-21':[(None,[2021,2020])],
        'p2-stroke-24':[([317.5,-1000,1000,1000],[6626]),(None,[6844])],
        'p2-stroke-27':[(None,[6220,6237])],
        'p2-stroke-28':[([388,-1000,1000,1000],[241,242]),(None,[239,238,6241])],
        'p2-stroke-29':[(None,[7367,7368])],
        'p2-stroke-30':[(None,[6151,6152])],
        'p3-stroke-3':[(None,[6627])],
        'p3-stroke-4':[(None,[6845])],
    },
    'breeze':{'p2-stroke-6':[(None,[6172,5996,5995])]},
    'fracture':{
        'p14-stroke-3':[(None,[4236,4238])],
        'p18-stroke-1':[([120,240,132,1000],[4751]),([-1000,222,1000,1000],[4725,4813,4821,4822]),(None,[4753])],
    },
    'haven':{'p3-stroke-19':[(None,[229,230,6635,593])],'p6-stroke-1':[(None,[7191])]},
    'icebox':{
        'p8-stroke-3':[([328,246,1000,1000],[3734,3740]),(None,[3715,3716,3739])],
        'p4-stroke-2':[(None,[3741])],
    },
    'pearl':{
        'p23-stroke-9':[(None,[6127,6128,6129])],
        'p16-stroke-0':[([-1000,-1000,1000,194.5],[6961,6962]),(None,[6960])],
        'p16-stroke-1-p16-stroke-1-remainder-0':[(None,[6929])],
        'p16-stroke-1-p16-stroke-1-remainder-1':[(None,[6918,6919])],
        'p29-stroke-0':[(None,[6964])],
        'p8-stroke-0':[([-1000,181,121,1000],[6964]),(None,[6940,6944,6949,6950])],
    },
}


def review(name,specs):
    directory=OUT/name;models={s:read(directory/f'before-{s}.json.gz') for s in ['attack','defense']}
    objects=read(ROOT/f'supplemented-v2/world/{name}/geometry.json')['objects']
    alignment=read(ROOT/f'tactical-alignment-sides-v1/{name}.json');a=np.array(alignment['nativeToAttackSvg']);b=np.array(alignment['nativeToDefenseSvg'])
    linear=b[:,:2]@np.linalg.inv(a[:,:2]);offset=b[:,2]-linear@a[:,2];transform=[*linear[0],*linear[1],*offset]
    by_id={w['id']:w for w in models['attack']['walls']};defense_shapes=[polygon(w) for w in models['defense']['walls']]
    replacements={side:{} for side in models};evidence=[]
    for wid,parts in specs.items():
        original=by_id[wid];shape=polygon(original);target=affine_transform(shape,transform)
        mate=min(range(len(defense_shapes)),key=lambda i:target.hausdorff_distance(defense_shapes[i]))
        if name=='pearl' and wid=='p16-stroke-1-p16-stroke-1-remainder-0':
            # Earlier source-prop clips leave a 0.35 SVG-unit side difference.
            # Both named remainders belong to the same front crate; retain
            # each authored remainder exactly and change only its height.
            assert models['defense']['walls'][mate]['id']==wid
            assert target.hausdorff_distance(defense_shapes[mate])<.351
        else:assert target.hausdorff_distance(defense_shapes[mate])<.01
        originals={'attack':original,'defense':models['defense']['walls'][mate]}
        for side,wall in originals.items():
            remaining=polygon(wall);emitted=[]
            for index,(box,ids) in enumerate(parts):
                if wid=='p2-stroke-1' and name=='ascent':
                    # The artwork draws the upper rotated box as a diamond.
                    # Its painted outline, including the miter, owns this cap.
                    diamond=shapely.Polygon([(52.5,133),(57,128.5),(61.5,133),(57,137.5)]).buffer(.5,join_style='mitre')
                    regions=[(diamond,[3027]),(None,[3029,3028])]
                else:regions=[(shapely.box(*box) if box else None,ids)]
                for local,(domain,source_ids) in enumerate(regions):
                    if domain is None:piece=remaining
                    else:piece=remaining.intersection(affine_transform(domain,transform) if side=='defense' else domain)
                    if piece.is_empty:continue
                    top=max(objects[i]['boundsMeters'][1][2] for i in source_ids)
                    floor=min(0.,min(objects[i]['boundsMeters'][0][2] for i in source_ids))
                    for part_index,p in enumerate(shapely.get_parts(piece)):
                        if p.geom_type!='Polygon' or p.area<1e-12:continue
                        record=dict(wall)
                        if len(parts)>1 or len(regions)>1:record.update(id=f'{wall["id"]}-finite-{index}-{local}-{part_index}',rings=rings(p))
                        record.update(floorElevationMeters=float(floor),bands=[[0.,float(top-floor)]],unknownHeight=False)
                        emitted.append(record)
                    remaining=remaining.difference(piece)
                    if side=='attack':evidence.append(dict(wallId=wid,sourceObjects=source_ids,sourcePaths=[objects[i]['path'] for i in source_ids],maximumSourceZ=float(top),sourceFloor=float(floor),clipRings=None if domain is None else [r for p in shapely.get_parts(domain) for r in rings(p)]))
            assert remaining.area<1e-7
            assert polygon(wall).symmetric_difference(shapely.union_all([polygon(w) for w in emitted])).area<1e-7
            replacements[side][wall['id']]=emitted
    for side,model in models.items():
        model['walls']=[part for w in model['walls'] for part in replacements[side].get(w['id'],[w])]
        (directory/f'height-base-{side}.json.gz').write_bytes(gzip.compress(json.dumps(model,separators=(',',':'),allow_nan=False).encode(),mtime=0))
    (directory/'finite-prop-wall-review.json').write_text(json.dumps(dict(map=name,evidence=evidence,
        reason='The existing source associations identify closed standing props, not infinitely tall structures. Stacked boxes sharing one painted perimeter use their top assembly height; distinct drawn upper/lower outlines retain separate caps.'),indent=2))
    print(name,len(specs),'finite prop outlines',flush=True)


if __name__=='__main__':
    for name,specs in SPECS.items():review(name,specs)

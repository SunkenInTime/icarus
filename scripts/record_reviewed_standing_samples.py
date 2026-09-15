"""Freeze Dara's reviewed locations separately from extracted collision claims."""
from collections import Counter
import json
from pathlib import Path
import numpy as np
import shapely
from audit_all_map_gameplay_levels import ROOT, read
from build_all_physical_standing_surfaces import sha
from compile_reviewed_svg_height_map import rings

SOURCE = ROOT/'tactical-visibility-revision/all-map-standing-surfaces-v9'
DESTINATION = Path(__file__).parent/'data/gameplay-standing-review-2026-09-08.json'


def record():
    report=read(SOURCE/'unresolved-position-patterns.json')
    resolved=read(SOURCE/'reviewed-standing-height-resolution.json')
    by_position={(r['map'],tuple(r['nativeXY'])):r for r in resolved}
    maps={}
    for name in sorted({r['map'] for r in report['rows']}):
        geometry=ROOT/f'supplemented-v2/world/{name}/geometry.npz'
        metadata=geometry.with_suffix('.json')
        maps[name]=dict(sourceGeometrySha256=sha(geometry),sourceMetadataSha256=sha(metadata),
            alignmentSha256=sha(ROOT/f'tactical-alignment-sides-v1/{name}.json'),samples=[])
        for index,row in enumerate(report['rows']):
            if row['map']!=name:continue
            measured=by_position[name,tuple(row['nativeXY'])]
            clear=[r for r in measured['physicalCandidates'] if not r['exclusions']]
            physical=clear[0] if clear else min(measured['physicalCandidates'],key=lambda r:abs(r['navDifference']),default=None)
            maps[name]['samples'].append(dict(id=f'reviewed-standing-{index:03d}',
                sourceObject=row['sourceObject'],sourcePath=row['sourcePath'],sourceFace=row['sourceFace'],
                nativeXY=row['nativeXY'],originSvg=row['originSvg'],renderedElevationMeters=row['physicalFloorMeters'],
                navigationElevationMeters=row['navElevationMeters'],gameplayStandingAllowed=True,
                sourceCollision=row['sourceCollision'],
                physicalFloor=physical,
                extractedClearanceDisagreement=physical['exclusions'] if physical else measured['oldExclusions']))
    geometry=np.load(ROOT/'supplemented-v2/world/bind/geometry.npz')
    obj=read(ROOT/'supplemented-v2/world/bind/geometry.json')['objects'][6744]
    ids=np.arange(obj['firstFace'],obj['firstFace']+obj['faceCount'])
    triangles=geometry['points'][geometry['faces'][ids]].astype(float)
    center=(triangles[:,:,:2].min(axis=(0,1))+triangles[:,:,:2].max(axis=(0,1)))/2
    radii=np.linalg.norm(triangles[:,:,:2]-center,axis=2)
    # These measured source layers isolate the raised star-shaped basin wall.
    # Its central bowl and the outer octagonal basin are separate faces.
    selected=(triangles[:,:,2].min(axis=1)>1.78)&(triangles[:,:,2].max(axis=1)>2.09)&(radii.min(axis=1)>1.)
    footprint=shapely.union_all(shapely.polygons(triangles[selected,:,:2]),grid_size=1e-7)
    parts=[p for p in shapely.get_parts(footprint) if p.geom_type=='Polygon' and p.area>1e-10]
    assert len(parts)==1
    holes=[h for h in parts[0].interiors if shapely.Polygon(h).area>1e-8]
    assert len(holes)==1
    band=shapely.Polygon(parts[0].exterior,holes)
    assert not band.covers(shapely.Point(center))
    fountain=[r for r in maps['bind']['samples'] if r['sourceObject']==6744]
    assert len(fountain)==203
    assert not any(band.covers(shapely.Point(r['nativeXY'])) for r in fountain)
    maps['bind']['exclusions']=[dict(id='bind-fountain-inner-ring',sourceObject=6744,
        sourcePath=obj['path'],sourceFaces=ids[selected].tolist(),nativeRings=rings(band),
        fillRule='evenodd',areaSquareMeters=band.area,
        decision='Exclude only the narrow inner ring itself. Keep its center and the surrounding basin eligible.')]
    result=dict(schemaVersion=1,reviewer='Dara',reviewDate='2026-09-08',
        statements=["I inspected it you can stand on all samples on all maps",
            "the fountain you have to aviod the inner ring but then you're fine",
            "Only the narrow ring itself"],
        reviewedMapUrl='https://dara-pc-duo.tailba589e.ts.net:8445/',
        reviewedFragmentSha256=sha(Path('work/unresolved-standing-positions.html')),
        sampleReportSha256=sha(SOURCE/'unresolved-position-patterns.json'),
        sampleCount=454,sourceObjectRecords=40,
        policy='Gameplay review establishes standing eligibility at the recorded locations. '
            'The selected local source faces supply measured geometry; this does not declare an entire object or inherited collision profile standable. '
            'Measured player-collision floors take precedence over a rendered face below them. '
            'Retain extraction disagreements as evidence, not as vetoes on the explicit gameplay review.',
        maps=maps)
    assert sum(len(r['samples']) for r in maps.values())==454
    DESTINATION.write_text(json.dumps(result,indent=2)+'\n')
    print(json.dumps(dict(path=str(DESTINATION),samples=454,
        measuredCollisionFloors=sum(r['physicalFloor'] is not None for m in maps.values() for r in m['samples']),
        retainedExtractionDisagreements=sum(bool(r['extractedClearanceDisagreement']) for m in maps.values() for r in m['samples']),
        fountainRingAreaSquareMeters=band.area,fountainRingFaces=int(selected.sum()),excludedReviewedSamples=0)))


if __name__=='__main__':record()

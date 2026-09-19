"""Compile Pearl's source-measured Mid slope without changing any wall."""
import gzip
import hashlib
import json
from pathlib import Path
import numpy as np
import shapely
from compile_reviewed_svg_height_map import polygon, rings
from source_geometry_projection import project_source
from verify_icebox_regional_floors import applicable_domain, area_shape, svg_plane

def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()

def main():
    review_path = Path('scripts/data/pearl-mid-slope-standing-2026-09-18.json')
    review = json.loads(review_path.read_bytes())
    source_spec = review['baselineSource']
    assert sha(source_spec['sourcePath']) == source_spec['sourceSha256']
    source = json.loads(Path(source_spec['sourcePath']).read_bytes())
    assert review['pointCovered'] and review['accountedCollisionBodies'] == 2824
    for path, digest in review['sourceInputs'].items():
        assert sha(path) == digest, path
    identities = {d['id'] for d in review['domains']}
    assert not identities.intersection(d['id'] for d in source['domains'])
    source['domains'].extend(review['domains'])
    source['sourceRows'] = [review['row'] if r.get('sourceCollision') == review['row']['sourceCollision'] else r
                            for r in source['sourceRows']]
    source['midSlopePrecisionReviewSha256'] = sha(review_path)
    output = Path('work/pearl-cutoff-2026-09-18/regional-floors.json')
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(source))
    alignment = json.loads(Path('E:/IcarusWorldAudit/2026-09-06/tactical-alignment-sides-v1/pearl.json').read_bytes())
    for side in ['attack', 'defense']:
        path = Path(f'assets/maps/pearl_svg_height_{side}.json.gz')
        model = json.loads(gzip.decompress(path.read_bytes()))
        matrix = np.array(alignment[f'nativeTo{side.title()}Svg'])
        receiver = shapely.union_all([polygon(r) for r in model['receiver']])
        for item in review['domains']:
            sid = 'pearl-measured-' + item['id']
            model['supports'] = [s for s in model['supports'] if s['id'] != sid]
            native = shapely.from_geojson(json.dumps(item['nativeGeometry']))
            domain = area_shape(project_source(native,[*matrix[0,:2],*matrix[1,:2],*matrix[:,2]]).intersection(receiver))
            plane = svg_plane(item['nativePlane'],matrix)
            domain = applicable_domain(domain,plane,model['walls'])
            if domain.is_empty: continue
            point=domain.representative_point(); z=float(plane@[point.x,point.y,1])
            model['supports'].append(dict(id=sid,label='Mid slope',fillRule='evenodd',
                rings=[r for part in shapely.get_parts(domain) if part.geom_type=='Polygon' for r in rings(part)],
                floorElevationMeters=0.,heightAboveFloorMeters=z,surfaceElevationMeters=z,
                surfacePlane=plane.tolist(),automaticStandingAllowed=True))
        model['sourceMidSlopePrecisionReviewSha256'] = sha(review_path)
        path.write_bytes(gzip.compress(json.dumps(model).encode(),mtime=0))
    manifest_path=Path('scripts/data/map-standing-source-manifest.json')
    manifest=json.loads(manifest_path.read_bytes())
    manifest['maps']['pearl']=dict(sourcePath=output.as_posix(),sourceSha256=sha(output))
    manifest_path.write_text(json.dumps(manifest,indent=2)+'\n')

if __name__=='__main__': main()

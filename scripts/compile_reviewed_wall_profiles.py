"""Distill reviewed planar wall triangles into exact along-wall/height regions.

Experimental data only. This preserves the candidate's provisional height
policy; it does not certify gameplay or replace unreviewed scene geometry.
"""
import argparse
import gzip
import hashlib
import json
from pathlib import Path
import numpy as np
import shapely
from tactical_alignment_audit import pack
from tactical_alignment_composite import explicit_warp
from verify_normalized_wall_profiles import profile_frame


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def union_profiles(triangles):
    polygons = shapely.polygons(triangles)
    assert shapely.is_valid(polygons).all(), 'Invalid source wall profile'
    result = shapely.union_all(polygons)
    assert result.is_valid
    return result


def compile_profiles(candidate, warp_path, output):
    if output.exists():
        raise FileExistsError(output)
    binding_path = candidate / 'bindings.json'
    bindings = json.loads(binding_path.read_text())
    warp = json.loads(gzip.decompress(warp_path.read_bytes()))
    assert sha(warp_path) == bindings['displayWarpSha256']
    pack_path = candidate / (warp['map'] + '.height.bin.gz')
    proof_path = candidate / 'independent-profile-review.json'
    proof = json.loads(proof_path.read_text())
    assert proof['candidatePackSha256'] == sha(pack_path)
    assert proof['wallBindingsSha256'] == sha(binding_path)
    header, scene = pack(pack_path)
    provenance = np.load(candidate / 'normalized-face-provenance.npz')
    matrix = np.column_stack((warp['projection']['axisU'], warp['projection']['axisV']))
    origin = np.array(warp['projection']['origin'])
    source_svg = np.array(warp['sourceNativeMeters']).reshape(-1, 2) @ matrix.T + origin
    target_svg = np.array(warp['targetAttackSvg']).reshape(-1, 2)
    forward = explicit_warp(source_svg, target_svg - source_svg, np.array(warp['triangles']).reshape(-1, 3))
    families = []
    records = []
    for family in bindings['families']:
        ids = provenance['generatedFaceIds'][provenance['generatedEdges'] == family['edge']]
        triangles = scene['vertices'][scene['faces'][ids]]
        xy = triangles[:, :, :2] @ matrix.T + origin
        displayed = forward.apply(xy.reshape(-1, 2)).reshape(xy.shape)
        o, t, n = profile_frame(family, 'target')
        along = (displayed - o) @ t
        profiles = np.stack((along, triangles[:, :, 2]), axis=2)
        masks = scene['faceMasks'][ids]
        opaque = masks < 0
        region = union_profiles(profiles[opaque])
        encoded = shapely.to_geojson(region)
        decoded = shapely.from_geojson(encoded)
        assert region.equals_exact(decoded, tolerance=0)
        masked = []
        for triangle, mask, face_id in zip(profiles[~opaque], masks[~opaque], ids[~opaque]):
            masked.append(dict(profile=triangle.tolist(), uv=scene['maskedUvs'][mask].tolist(),
                               material=int(scene['maskedMaterials'][mask]), candidateFace=int(face_id)))
        families.append(dict(edge=family['edge'], targetFrame=dict(origin=o.tolist(), tangent=t.tolist(), normal=n.tolist()),
                             targetAlong=family['targetAlong'], opaqueRegion=json.loads(encoded), maskedProfiles=masked))
        records.append(dict(edge=family['edge'], sourceTriangles=len(ids), opaqueTriangles=int(opaque.sum()),
                            boundaryVertices=int(shapely.get_num_coordinates(region)),
                            polygonParts=int(shapely.get_num_geometries(region)), maskedTriangles=len(masked),
                            exactSerializationRoundTrip=True))
    data = dict(format='icarus-reviewed-wall-profiles-v1', version=1, map=warp['map'],
                candidatePackSha256=sha(pack_path), bindingsSha256=sha(binding_path),
                displayWarpSha256=sha(warp_path), independentProfileProofSha256=sha(proof_path),
                compilerSha256=sha(Path(__file__)), coordinatePolicy='Authored SVG along distance and unchanged candidate height in meters',
                heightPolicy=bindings.get('heightPolicy', 'Unchanged provisional candidate heights'),
                alphaPolicy='Masked triangles retain original UV/material references; material data remains in the source pack',
                simplificationTolerance=0, families=families)
    raw = json.dumps(data, separators=(',', ':')).encode()
    compressed = gzip.compress(raw, mtime=0)
    output.mkdir(parents=True)
    (output / 'wall-profiles.json.gz').write_bytes(compressed)
    report = dict(scope=__doc__, candidatePackSha256=sha(pack_path), bytes=len(compressed), rawBytes=len(raw),
                  profileDataSha256=hashlib.sha256(compressed).hexdigest(), families=records,
                  productionMutation=False, timingMeasured=False,
                  limitations=['Only reviewed planar families are represented.', 'Masked material data is referenced, not embedded.',
                               'Existing source height policy remains provisional.', 'Runtime query integration and performance are untested.'])
    (output / 'report.json').write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(report, indent=2))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('candidate', type=Path)
    parser.add_argument('warp', type=Path)
    parser.add_argument('output', type=Path)
    args = parser.parse_args()
    compile_profiles(args.candidate, args.warp, args.output)

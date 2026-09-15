"""Recheck capsule exclusions against complete source collider boundaries.

This verifier reads no runtime asset. Convexity and outward planes come from
the archived collider triangles, independently of the builder's hull planes.
"""
import argparse
import hashlib
import json
from pathlib import Path
import numpy as np
import shapely


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def outward_planes(triangles):
    vertices, indices = np.unique(triangles.reshape(-1, 3), axis=0, return_inverse=True)
    indices = indices.reshape(-1, 3)
    edges = np.sort(np.concatenate([indices[:, [0,1]], indices[:, [1,2]], indices[:, [2,0]]]), axis=1)
    assert np.all(np.unique(edges, axis=0, return_counts=True)[1] == 2), 'Containing body is not closed'
    normals = np.cross(triangles[:,1]-triangles[:,0], triangles[:,2]-triangles[:,0])
    lengths = np.linalg.norm(normals, axis=1)
    assert np.all(lengths > 1e-12)
    normals /= lengths[:, None]
    reverse = np.einsum('ij,ij->i', normals, triangles[:,0]-vertices.mean(0)) < 0.
    normals[reverse] *= -1
    offsets = -np.einsum('ij,ij->i', normals, triangles[:,0])
    assert np.max(vertices@normals.T+offsets) < 1e-8, 'Containing boundary is not convex'
    return normals, offsets


def scaled_capsule(record, source_element):
    assert record['sourceElement'] == source_element
    matrix = np.array(record['sourceMatrix'])
    scales = np.sqrt(np.sum(matrix[:3,:3]**2, axis=1))
    axes = matrix[:3,:3]/scales[:,None]
    assert np.linalg.det(matrix[:3,:3]) > 0
    np.testing.assert_allclose(axes@axes.T, np.eye(3), atol=1e-9)
    rotation = source_element['Rotation']
    local_axis = np.array([0., 0., 1.])
    if any(rotation.values()):
        assert rotation['Yaw'] == rotation['Roll'] == 0. and abs(rotation['Pitch']) == 90.
        angle = np.deg2rad(rotation['Pitch'])
        local_axis = np.array([-np.sin(angle), 0., np.cos(angle)])
    axis = local_axis @ axes
    total = max(.001, .005*(source_element['Length']+2*source_element['Radius'])*scales[2])
    radius = min(total, max(.001, .01*source_element['Radius']*max(scales[0],scales[1])))
    half = max(.0005,total-radius)
    local = np.array([source_element['Center'][k] for k in 'XYZ'])*[1.,-1.,1.]
    center = (matrix[3,:3]+local@matrix[:3,:3])/100.
    np.testing.assert_allclose(center, record['centerMeters'], atol=1e-10)
    np.testing.assert_allclose(axis, record['axis'], atol=1e-10)
    assert abs(radius-record['radiusMeters']) < 1e-10
    assert abs(half-record['segmentHalfLengthMeters']) < 1e-10
    extent = radius+np.abs(axis)*half
    np.testing.assert_allclose([center-extent,center+extent],record['bounds'],atol=1e-10)
    return center, axis, radius, half


def verify_column_union(capsule, shape, colliders, ids, triangles):
    center, axis, radius, half = shape
    expansion = capsule['expansionMeters']
    assert expansion >= .001
    extent = np.abs(axis)*half+radius+expansion
    lo, hi = center-extent, center+extent
    np.testing.assert_allclose(capsule['prismBounds'], [lo, hi], atol=1e-10)
    intervals = capsule['containingVolumes']
    assert intervals
    intervals = sorted(intervals, key=lambda r: r['lowerMeters'])
    assert abs(intervals[0]['lowerMeters']-lo[2]) <= 1e-10
    reached = intervals[0]['lowerMeters']
    for item in intervals:
        lower, upper = item['lowerMeters'], item['upperMeters']
        assert lo[2]-1e-10 <= lower <= reached and lower <= upper <= hi[2]+1e-10
        index = ids[item['sourceCollision']]
        assert not colliders[index].get('kill') and not colliders[index].get('collisionDefaultsUnknown')
        normals, offsets = outward_planes(triangles[str(index)])
        corners = np.array([[x,y,z] for x in [lo[0],hi[0]]
            for y in [lo[1],hi[1]] for z in [lower,upper]])
        assert np.max(corners@normals.T+offsets) <= 1e-9, 'Claimed prism leaves the source solid'
        reached = max(reached, upper)
    assert reached >= hi[2]-1e-10


def verify(source):
    inventory = json.loads((source/'source-inventory.json').read_bytes())
    accounting = json.loads((source/'collision-accounting.json').read_bytes())
    assert not accounting['unresolved']
    objects = {r['sourceObject']: r for r in inventory['inventory']}
    colliders = json.loads((source/'source-colliders.json').read_bytes())
    ids = {r['id']: i for i,r in enumerate(colliders)}
    region = shapely.from_geojson(json.dumps(inventory['sourceRegion']))
    checked = []
    with np.load(source/'source-colliders.npz') as triangles:
        for oid, proof in accounting.get('redundantCollision', {}).items():
            source_elements = objects[int(oid)]['evidence']['bodySetup']['AggGeom']['SphylElems']
            assert len(source_elements) == len(proof['capsules'])
            source_boxes = objects[int(oid)]['evidence']['bodySetup']['AggGeom'].get('BoxElems', [])
            assert len(source_boxes) == len(proof.get('boxes', []))
            for part, box in enumerate(proof.get('boxes', [])):
                element = source_boxes[part]
                assert box['sourceElement'] == element
                assert not any(element['Rotation'].values())
                assert element.get('RestOffset', 0.) == 0.
                matrix = np.asarray(box['sourceMatrix'])
                scales = np.linalg.norm(matrix[:3,:3], axis=1)
                assert np.isfinite(matrix).all() and min(scales) > 0.
                axes = matrix[:3,:3]/scales[:,None]
                np.testing.assert_allclose(axes@axes.T, np.eye(3), atol=1e-9)
                half = np.maximum(np.array([element[k] for k in 'XYZ'])/2, .0001/scales)
                local_center = np.array([element['Center'][k] for k in 'XYZ'])
                corners = np.array([local_center+half*[x,y,z] for x in [-1,1] for y in [-1,1] for z in [-1,1]])
                vertices = ((corners*[1,-1,1])@matrix[:3,:3]+matrix[3,:3])/100
                np.testing.assert_allclose(np.unique(vertices,axis=0), box['verticesMeters'], atol=1e-10)
                assert box['containingVolumes']
                for containing in box['containingVolumes']:
                    index = ids[containing['sourceCollision']]
                    assert not colliders[index].get('kill')
                    normals, offsets = outward_planes(triangles[str(index)])
                    inset = float(-(vertices@normals.T+offsets).max())
                    assert inset > .001
                    assert abs(inset-containing['minimumInsetMeters']) < 1e-8
                    checked.append(dict(sourceObject=int(oid),part=part,kind='contained-box',
                        containingCollision=containing['sourceCollision'],minimumInsetMeters=inset))
            for part, capsule in enumerate(proof['capsules']):
                if 'analyticCapsule' in capsule:
                    center, axis, radius, half = scaled_capsule(capsule['analyticCapsule'], source_elements[part])
                else:
                    center = np.array(capsule['centerMeters']); axis = np.array(capsule['axis'])
                    radius = capsule['radiusMeters']; half = capsule['segmentHalfLengthMeters']
                    if 'sourceMatrix' in capsule:
                        element = source_elements[part]
                        assert capsule['sourceElement'] == element
                        assert element.get('RestOffset', 0.) == 0.
                        matrix = np.asarray(capsule['sourceMatrix'])
                        scales = np.linalg.norm(matrix[:3,:3], axis=1)
                        assert np.isfinite(matrix).all() and min(scales) > 0.
                        axes = matrix[:3,:3]/scales[:,None]
                        np.testing.assert_allclose(axes@axes.T, np.eye(3), atol=1e-9)
                        local = np.array([element['Center'][k] for k in 'XYZ'])*[1,-1,1]
                        np.testing.assert_allclose(center,(local@matrix[:3,:3]+matrix[3,:3])/100,atol=1e-10)
                        if capsule.get('boundKind') == 'conservative-enclosing-sphere':
                            expected = max(.001,(element['Length']/2+element['Radius'])*max(scales)/100)+.0005
                            assert abs(radius-expected)<1e-10 and half == 0.
                        else:
                            assert not any(element['Rotation'].values())
                            np.testing.assert_allclose(scales,scales[0],atol=1e-9,rtol=1e-9)
                            assert abs(radius-element['Radius']*scales[0]/100)<1e-10
                            assert abs(half-element['Length']*scales[0]/200)<1e-10
                            np.testing.assert_allclose(axis,axes[2],atol=1e-10)
                assert capsule['containingVolumes']
                if capsule.get('boundKind') == 'convex-volume-column-union':
                    verify_column_union(capsule, (center, axis, radius, half), colliders, ids, triangles)
                    checked.append(dict(sourceObject=int(oid), part=part, kind='contained-volume-union',
                        expansionMeters=capsule['expansionMeters'], volumes=len(capsule['containingVolumes'])))
                    continue
                for containing in capsule['containingVolumes']:
                    normals, offsets = outward_planes(triangles[str(ids[containing['sourceCollision']])])
                    # For each plane, choose the endpoint and spherical point
                    # that are furthest toward its exterior. This checks the
                    # complete curved capsule, including its cylinder sides.
                    extreme = (center+half*np.sign(normals@axis)[:,None]*axis+radius*normals)
                    distance = np.einsum('ij,ij->i', normals, extreme)+offsets
                    inset = float(-distance.max())
                    assert inset > .001
                    assert abs(inset-containing['minimumInsetMeters']) < 1e-8
                    checked.append(dict(sourceObject=int(oid),part=part,kind='contained',
                        containingCollision=containing['sourceCollision'],minimumInsetMeters=inset))
        for oid, proof in accounting.get('outsideRegionCollision', {}).items():
            assert proof['sourceRegion'] == inventory['sourceRegion']
            assert proof['playerRadiusMeters'] == .42
            source_elements = objects[int(oid)]['evidence']['bodySetup']['AggGeom']['SphylElems']
            assert len(source_elements) == len(proof['capsules'])
            for part, item in enumerate(proof['capsules']):
                center,axis,radius,half = scaled_capsule(item['capsule'],source_elements[part])
                lo,hi = center-np.abs(axis)*half-radius,center+np.abs(axis)*half+radius
                distance = region.distance(shapely.box(*lo[:2],*hi[:2]))
                assert distance > .421
                assert abs(distance-item['distanceToRegionMeters']) < 1e-8
                checked.append(dict(sourceObject=int(oid),part=part,kind='outside-region',distanceToRegionMeters=distance))
    report = dict(status='passed',records=checked,algorithmSha256=sha(Path(__file__)),
        inputsSha256={name:sha(source/name) for name in ['source-inventory.json',
            'collision-accounting.json','source-colliders.json','source-colliders.npz']})
    (source/'capsule-exclusion-verification.json').write_text(json.dumps(report,indent=2)+'\n')
    print(json.dumps(report))
    return report


if __name__ == '__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source',type=Path,required=True)
    verify(parser.parse_args().source)

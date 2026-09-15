"""Source identities and selective standing-floor policy for offline baking."""
import hashlib
import json
from pathlib import Path

import numpy as np


def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def checked_local(folder, filename, fingerprint):
    if not isinstance(filename, str) or Path(filename).name != filename:
        raise ValueError('Ground evidence must use a local filename.')
    path = Path(folder) / filename
    if digest(path) != fingerprint:
        raise ValueError('Ground evidence fingerprint mismatch.')
    return path


def ground_policy_mask(world, metadata, raw, navigation):
    points, faces, material_ids = raw['points'], raw['faces'], raw['material_indices']
    xyz = points[faces]
    normal = np.cross(xyz[:,1]-xyz[:,0], xyz[:,2]-xyz[:,0])
    solid = np.asarray([m['category'] in ('opaque','unresolved') for m in metadata['materials']])
    allowed = (normal[:,2] > .65*np.linalg.norm(normal,axis=1)) & solid[material_ids]
    proof, support_data = {}, None
    authored = np.ones(len(faces), dtype=bool)
    if metadata.get('groundSupport'):
        descriptor = metadata['groundSupport']
        path = checked_local(world, descriptor['file'], descriptor['sha256'])
        support_data = json.loads(path.read_bytes())
        if (support_data.get('schemaVersion') != 1 or support_data.get('map') != metadata.get('map') or
                support_data.get('geometrySha256') != metadata['geometrySha256'] or
                support_data.get('faceCount') != len(faces) or
                support_data.get('sourceNavigationXYZSha256') != digest(navigation)):
            raise ValueError('Ground support does not identify these source faces/navigation.')
        source_path = checked_local(world, support_data['sourceProofFile'], support_data['sourceProofSha256'])
        source_proof = json.loads(source_path.read_bytes())
        source_map = next((m for m in source_proof.get('maps', [])
                           if m.get('map') == metadata.get('map')), None)
        if (source_map is None or
                source_map.get('nativeCandidateGeometrySha256') != metadata['geometrySha256']):
            raise ValueError('Pawn support proof identifies another Art source.')
        source_ranges = {p['firstFace']: p for p in source_map['placements']}

        def verify_range(row, classification):
            first, count = row['firstFace'], row['faceCount']
            source = source_ranges.get(first)
            if (type(first) is not int or type(count) is not int or first < 0 or count <= 0 or
                    first+count > len(faces) or source is None or source['faceCount'] != count or
                    source['classification'] != classification or
                    row.get('sourceRecordId') != f"{metadata['map']}:{first}"):
                raise ValueError('Ground support range does not match its native proof.')
            return first, count
        if support_data.get('defaultMode') == 'baseline-geometric-winding':
            if support_data.get('baselinePointsDtype') != str(points.dtype):
                raise ValueError('Ground baseline precision differs from original Art.')
            authored[:] = False
            for row in support_data.get('authoredFacingRanges', []):
                first, count = verify_range(row, 'declared-pawn-blocking-complex')
                authored[first:first+count] = True
        else:
            raise ValueError('Unsupported selective ground policy.')
        proof['groundSupportSha256'] = descriptor['sha256']
    if metadata.get('groundFacing'):
        from world_visibility_ray_reference import load_ground_facing
        descriptor = metadata['groundFacing']
        native = json.loads(Path(navigation).read_bytes())
        signs, info = load_ground_facing(world, metadata,
            {'geometrySha256': metadata['geometrySha256'], 'groundFacingSha256': descriptor['sha256'],
             'sourceXYZSha256': digest(navigation), 'navigationSha256': native['navigationSha256']},
            metadata['geometrySha256'], len(faces), source_arrays=(points,faces,material_ids))
        precise = xyz[authored].astype(np.float64)
        normal = np.cross(precise[:,1]-precise[:,0],precise[:,2]-precise[:,0])
        allowed[authored] = ((normal[:,2]*signs[authored] > .65*np.linalg.norm(normal,axis=1)) & solid[material_ids[authored]])
        excluded = np.asarray(info.get('excludedSourceFaces', []), dtype=int)
        allowed[excluded[authored[excluded]]] = False
        proof['groundFacingSha256'] = descriptor['sha256']
    elif support_data and authored.any():
        raise ValueError('Confirmed authored ranges require source-facing evidence.')
    if support_data:
        for row in support_data.get('excludedRanges', []):
            first,count=verify_range(row, 'excluded-explicit-pawn-nonblocking')
            allowed[first:first+count]=False
    return allowed, proof, support_data


class FloorOverrides:
    """Native support hulls restricted to verified Art and navigation regions."""
    def __init__(self, world, raw, support):
        import shapely
        self.entries = []
        if not support:
            return
        for record in support.get('overrideFloorMeshes', []):
            path = checked_local(world, record['file'], record['sha256'])
            checked_local(world, record['sourceProofFile'], record['sourceProofSha256'])
            hull = np.load(path, allow_pickle=False)
            points, faces = hull['points'], hull['faces']
            if (points.ndim != 2 or points.shape[1] != 3 or faces.ndim != 2 or faces.shape[1] != 3 or
                    not np.isfinite(points).all() or faces.min()<0 or faces.max()>=len(points)):
                raise ValueError('Invalid native collision support mesh.')
            triangles = points[faces].astype(np.float64)
            normals = np.cross(triangles[:,1]-triangles[:,0],triangles[:,2]-triangles[:,0])
            triangles = triangles[normals[:,2]>.65*np.linalg.norm(normals,axis=1)]
            ids = np.asarray(record['scopeArtFaces'], dtype=int)
            if not len(ids) or ids.min()<0 or ids.max()>=len(raw['faces']):
                raise ValueError('Support scope does not identify original Art faces.')
            scope_xyz = raw['points'][raw['faces'][ids]]
            scope = shapely.union_all(shapely.polygons(scope_xyz[:,:,:2]))
            parents = set(record['parentNavPolygons'])
            if not parents or any(type(p) is not int or p<0 for p in parents):
                raise ValueError('Support scope requires native parent polygon IDs.')
            self.entries.append((triangles,scope_xyz,scope,parents))

    def pieces(self, parent, native_triangle):
        import shapely
        from bake_navigation_floors import plane, clip_halfplane
        result=[]
        nav_shape=shapely.Polygon(native_triangle[:,:2])
        nav_plane=plane(native_triangle)
        def clipped_piece(triangle):
            intersection=shapely.Polygon(triangle[:,:2]).intersection(nav_shape)
            if intersection.geom_type!='Polygon' or intersection.area<1e-8:
                return None
            coefficients=plane(triangle)
            difference=coefficients-nav_plane
            points=clip_halfplane(list(intersection.exterior.coords)[:-1],difference,.30001)
            points=clip_halfplane(points,-difference,.60001)
            if len(points)<3:
                return None
            piece=shapely.Polygon(points)
            return (coefficients,piece) if piece.area>=1e-8 else None

        for triangles,scope_xyz,scope,parents in self.entries:
            if parent not in parents or not scope.intersects(nav_shape):
                continue
            scope_pieces=[piece[1] for triangle in scope_xyz
                          if (piece:=clipped_piece(triangle)) is not None]
            if not scope_pieces:
                continue
            scoped_domain=shapely.union_all(scope_pieces)
            for triangle in triangles:
                clipped=clipped_piece(triangle)
                if clipped is None:
                    continue
                coefficients,piece=clipped
                piece=piece.intersection(scoped_domain)
                if piece.area>=1e-8:
                    result.append((coefficients,piece))
        return result

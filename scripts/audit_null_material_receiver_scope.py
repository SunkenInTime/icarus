"""Add actual authored receiver overlap to frozen null material face inventory."""
import gzip
import hashlib
import json
from pathlib import Path
import numpy as np
import shapely
from tactical_alignment_receiver import receiver_domain
from verify_display_warp_scope import mapped_domain


def source_receiver(revision, name):
    path = revision / f'display-warps-v1/{name}.display-warp.json.gz'
    display = json.loads(gzip.decompress(path.read_bytes()))
    projection = display['projection']
    matrix = np.column_stack((projection['axisU'], projection['axisV']))
    origin = np.asarray(projection['origin'])
    inverse = np.linalg.inv(matrix)
    source = np.asarray(display['sourceNativeMeters']).reshape(-1, 2)
    target = (np.asarray(display['targetAttackSvg']).reshape(-1, 2) - origin) @ inverse.T
    triangles = np.asarray(display['triangles']).reshape(-1, 3)
    parts = []
    for side, suffix in [('attack', ''), ('defense', '_defense')]:
        artwork = Path(f'assets/maps/{name}_map{suffix}.svg')
        assert hashlib.sha256(artwork.read_bytes()).hexdigest() == display['art'][side]['sha256']
        shape = receiver_domain(artwork)
        if side == 'defense':
            translation = np.asarray(display['attackToDefenseSvg']['origin'])
            shape = shapely.transform(shape, lambda xy: translation - xy)
        parts.append(shapely.transform(shape, lambda xy: (xy - origin) @ inverse.T))
    return mapped_domain(shapely.union_all(parts), target, source, triangles)


def main():
    revision = Path('E:/IcarusWorldAudit/2026-09-06/tactical-visibility-revision')
    out = revision / 'null-material-fallback-audit-v1'
    worlds = json.loads((revision.parent / 'completeness/combined-manifest-release-inputs-v2.json').read_text())
    summary = []
    for world in worlds:
        name = world['map']
        path = out / f'{name}.json'
        report = json.loads(path.read_text())
        if not report['rows']:
            continue
        receiver = source_receiver(revision, name)
        raw = np.load(Path(world['combinedWorldFolder']) / 'geometry.npz')
        points, faces = raw['points'], raw['faces']
        rows = []
        for row in report['rows']:
            triangles = points[faces[row['originalSourceFaceIds']]]
            footprint = shapely.union_all([shapely.MultiPoint(triangle[:, :2]).convex_hull for triangle in triangles])
            overlap = footprint.intersection(receiver)
            row['actualReceiverOverlap'] = {'intersects': not overlap.is_empty, 'areaMeters2': float(overlap.area), 'lengthMeters': float(overlap.length), 'basis': 'Exact inverse piecewise-affine display W of both authored SVG base fills. Bezier flatten error <=1e-5 SVG units. Vertical faces retain line footprints.'}
            rows.append({'materialIndex': row['materialIndex'], 'faces': row['retainedFaceCount'], 'source': row['nullExportPath'], 'intersectsReceiver': not overlap.is_empty, 'heightPriority': row['overlapsGlobalStandingEyeHeightRange'], 'overlapAreaMeters2': float(overlap.area)})
        report['receiverDisplayWarpSha256'] = hashlib.sha256((revision / f'display-warps-v1/{name}.display-warp.json.gz').read_bytes()).hexdigest()
        path.write_text(json.dumps(report, indent=2))
        summary.append({'map': name, 'rows': rows})
        print(name, [(r['materialIndex'], r['faces'], r['intersectsReceiver'], r['heightPriority']) for r in rows], flush=True)
    (out / 'receiver-priority.json').write_text(json.dumps(summary, indent=2))


if __name__ == '__main__':
    main()

"""Find original 3D vertex contacts outside a proposed region's source membership.

This is a pre-bake review list. Contact does not assign a blocker role or authorize
moving the neighboring object. Edge-interior and non-touching attachments need
the separate source-section and rendered first-hit audits.
"""
import argparse
import hashlib
import json
from pathlib import Path

import numpy as np
from scipy.spatial import cKDTree

ROOT = Path('E:/IcarusWorldAudit/2026-09-06')


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def audit(name, declaration_path, output):
    if output.exists():
        raise FileExistsError(output)
    declaration = json.loads(declaration_path.read_text())
    path = ROOT/f'supplemented-v2/world/{name}/geometry.npz'
    meta = json.loads(path.with_suffix('.json').read_text())
    raw = np.load(path)
    raw_points, raw_faces = raw['points'], raw['faces']
    projection = ROOT/f'tactical-alignment-sides-v1/{name}.json'
    affine = np.array(json.loads(projection.read_text())['nativeToAttackSvg'])
    starts = np.array([o['firstFace'] for o in meta['objects']])
    selected_ids = np.asarray(declaration.get('reviewedSourceFaces', declaration.get('reviewedSourceFaceIds')), dtype=int)
    assert selected_ids.ndim == 1 and len(selected_ids)
    owners = np.searchsorted(starts, selected_ids, side='right')-1
    points = raw_points[raw_faces[selected_ids]].reshape(-1,3)
    owners = np.repeat(owners,3)
    xy = points[:,:2] @ affine[:,:2].T + affine[:,2]
    box = declaration['box']
    inside = (xy[:,0]>=box[0]) & (xy[:,1]>=box[1]) & (xy[:,0]<=box[2]) & (xy[:,1]<=box[3])
    records = np.unique(np.column_stack((points[inside], owners[inside])),axis=0)
    assert len(records)
    tree = cKDTree(records[:,:3])
    selected_objects = set(owners.tolist())
    selected_set = set(selected_ids.tolist())
    rows = []
    for obj_id, obj in enumerate(meta['objects']):
        ids = np.arange(obj['firstFace'], obj['firstFace']+obj['faceCount'])
        if obj_id in selected_objects:
            ids = np.array([i for i in ids if i not in selected_set], dtype=int)
        if not len(ids):
            continue
        vertex_ids = np.unique(raw_faces[ids])
        xyz = raw_points[vertex_ids]
        distances, _ = tree.query(xyz, distance_upper_bound=1e-9)
        matched = np.flatnonzero(np.isfinite(distances))
        if not len(matched):
            continue
        groups = {}
        for retained_index, neighbors in zip(matched, tree.query_ball_point(xyz[matched],1e-9)):
            for selected_index in neighbors:
                source_object = int(records[selected_index,3])
                group = groups.setdefault(source_object, set())
                group.add(int(retained_index))
        for source_object, indices in groups.items():
            indices = sorted(indices)
            shared = xyz[indices]
            projected = shared[:,:2] @ affine[:,:2].T + affine[:,2]
            rows.append(dict(selectedObject=source_object, retainedObject=obj_id,
                selectedPath=meta['objects'][source_object]['path'], retainedPath=obj['path'],
                retainedRole='unselected-faces-of-reviewed-object' if obj_id in selected_objects else 'unreviewed-object',
                distinctRetainedVertices=len(indices),
                contactBoundsSvg=[projected.min(0).tolist(),projected.max(0).tolist()],
                contactHeightRangeMeters=[float(shared[:,2].min()),float(shared[:,2].max())],
                sampleOriginalVertexIds=vertex_ids[indices[:8]].tolist(),
                sampleContactPointsMeters=shared[:8].tolist()))
    report = dict(scope=__doc__, map=name, region=declaration['edge'],
        sourceGeometrySha256=sha(path), sourceMetadataSha256=sha(path.with_suffix('.json')),
        declarationSha256=sha(declaration_path), projectionSha256=sha(projection),
        scriptSha256=sha(Path(__file__)), selectedSourceFaces=len(selected_ids),
        selectedVertexObjectRecords=len(records), sourceContactToleranceMeters=1e-9,
        groups=sorted(rows,key=lambda row:-row['distinctRetainedVertices']),
        requiresSemanticReview=True, productionMutation=False)
    output.parent.mkdir(parents=True,exist_ok=True)
    output.write_text(json.dumps(report,indent=2)+'\n')
    print(json.dumps(dict(groups=len(rows), neighbors=[(r['selectedObject'],r['retainedObject'],r['distinctRetainedVertices']) for r in report['groups']])),flush=True)


if __name__ == '__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('map')
    parser.add_argument('declaration',type=Path)
    parser.add_argument('output',type=Path)
    args=parser.parse_args()
    audit(args.map,args.declaration,args.output)

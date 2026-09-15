"""Measure coplanar opaque geometry available for offline compaction.

Rounded planes only propose groups. Every accepted group is checked against
every original vertex. Masked and ill-conditioned faces remain separate.
This inventory changes no geometry and makes no rendering-performance claim.
"""
import argparse
import hashlib
import json
from pathlib import Path
import time

import numpy as np

from tactical_alignment_audit import pack


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('pack', type=Path)
    parser.add_argument('out', type=Path)
    args = parser.parse_args()
    args.out.mkdir(parents=True, exist_ok=False)
    started = time.perf_counter()
    _, data = pack(args.pack)
    xyz = data['vertices'][data['faces']]
    first = xyz[:, 1]-xyz[:, 0]
    second = xyz[:, 2]-xyz[:, 0]
    normals = np.cross(first, second)
    magnitude = np.linalg.norm(normals, axis=1)
    scale = np.linalg.norm(first, axis=1)*np.linalg.norm(second, axis=1)
    eligible = (data['faceMasks'] < 0) & (magnitude > 1e-12*scale) & (magnitude > 0)
    ids = np.flatnonzero(eligible)
    normal = normals[ids]/magnitude[ids, None]
    axis = np.abs(normal).argmax(1)
    sign = np.where(normal[np.arange(len(ids)), axis] < 0, -1., 1.)
    normal *= sign[:, None]
    distance = np.einsum('ij,ij->i', normal, xyz[ids, 0])
    planes = np.c_[normal, distance]
    _, proposed = np.unique(np.round(planes, 8), axis=0, return_inverse=True)
    order = np.argsort(proposed, kind='stable')
    groups = np.split(order, np.flatnonzero(np.diff(proposed[order]))+1)
    accepted_planes, accepted_counts, accepted_error = [], [], []
    face_group = np.full(len(xyz), -1, dtype='<i4')
    rejected = 0
    for group in groups:
        if len(group) < 2:
            continue
        plane = planes[group[0]]
        error = float(np.abs(xyz[ids[group]] @ plane[:3]-plane[3]).max())
        if error > 1e-10:
            rejected += len(group)
            continue
        face_group[ids[group]] = len(accepted_planes)
        accepted_planes.append(plane)
        accepted_counts.append(len(group))
        accepted_error.append(error)
    output = args.out/'plane-groups.npz'
    np.savez_compressed(output, planes=np.asarray(accepted_planes),
                        faceGroups=face_group, counts=np.asarray(accepted_counts),
                        maximumVertexDistance=np.asarray(accepted_error))
    largest = np.argsort(-np.asarray(accepted_counts))[:20]
    report = dict(scope=__doc__, sourcePackSha256=sha(args.pack),
        sourcePack=str(args.pack), scriptSha256=sha(Path(__file__)),
        sourceTriangles=len(xyz), maskedTriangles=int((data['faceMasks'] >= 0).sum()),
        eligibleOpaqueTriangles=len(ids), acceptedMultiFacePlanes=len(accepted_planes),
        groupedOpaqueTriangles=int((face_group >= 0).sum()),
        residualTriangles=int((face_group < 0).sum()),
        rejectedProposedGroupFaces=rejected, planeDistanceLimitMeters=1e-10,
        maximumAcceptedVertexDistanceMeters=max(accepted_error, default=0.),
        largestGroups=[dict(group=int(g), faces=accepted_counts[g],
                            plane=accepted_planes[g].tolist(),
                            maximumVertexDistanceMeters=accepted_error[g]) for g in largest],
        assignmentBytes=output.stat().st_size, assignmentSha256=sha(output),
        elapsedSeconds=time.perf_counter()-started, productionPromotion=False,
        limitations=['Grouping alone does not reduce render geometry.',
                     'Polygon union, finite holes, source coverage, and ray equivalence still require verification.',
                     'Masked faces remain separate with their original UV and material data.'])
    (args.out/'report.json').write_text(json.dumps(report, indent=2)+'\n')
    print(json.dumps({k:v for k,v in report.items() if k not in ['scope','largestGroups','limitations']}), flush=True)


if __name__ == '__main__':
    main()

"""Recover original world heights for reviewed wall fragments.

This is a provenance bridge, not a new floor policy or runtime pack. Fragments
discarded under the temporary relative-height policy are checked again: a
zero-area relative profile need not have zero area in original world height.
"""
import argparse
import gzip
import hashlib
import json
from pathlib import Path

import numpy as np

from build_global_tactical_candidate import GroundField
from tactical_alignment_audit import pack
from verify_normalized_wall_profiles import profile_frame
from verify_normalized_wall_profiles import reconstruct_source_points
from verify_region_mapping import verify_rank_one_declarations
from precise_region_containment import certify_vertex_weights


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def triangle_barycentrics(points, triangles):
    basis = np.swapaxes(triangles[:, 1:] - triangles[:, :1], 1, 2)
    uv = np.einsum('nij,nkj->nki', np.linalg.pinv(basis), points - triangles[:, :1])
    bary = np.concatenate((1 - uv.sum(axis=2, keepdims=True), uv), axis=2)
    reconstructed = np.einsum('nij,njk->nik', bary, triangles)
    return bary, float(np.max(np.linalg.norm(reconstructed - points, axis=2), initial=0))


def area(profiles):
    a, b = profiles[:, 1] - profiles[:, 0], profiles[:, 2] - profiles[:, 0]
    return abs(a[:, 0] * b[:, 1] - a[:, 1] * b[:, 0]) * .5


def map_discarded_region(family, original, bary, cell_ids, matrix, origin, parents, hashes):
    """Recover declared display XY without changing original source Z.

    The source-partition proof has already checked these discarded fragments.
    A fragment dropped before region partitioning needs an explicit containing
    cell; it must pass the same provenance-based containment gate as other pieces.
    """
    source = reconstruct_source_points(bary, original)
    xy = source[:, :, :2] @ matrix.T + origin
    vertices = np.asarray(family['sourceVerticesSvg'], dtype=float)
    targets = np.asarray(family['targetVerticesSvg'], dtype=float)
    cells = np.asarray(family['triangles'], dtype=int)
    cell_ids = np.asarray(cell_ids, dtype=int).copy()
    construction = dict(originalNativeTriangles=original, sourceBarycentrics=bary,
        projectionMatrix=matrix, projectionOrigin=origin, sourceParents=parents,
        regionCells=cell_ids, inputHashes=hashes, family=family)
    for i in np.flatnonzero(cell_ids < 0):
        bounds = vertices[cells]
        candidates = np.flatnonzero((bounds.max(1) >= xy[i].min(0) - 1e-10).all(1)
            & (bounds.min(1) <= xy[i].max(0) + 1e-10).all(1))
        for cell in candidates:
            local = dict(construction, originalNativeTriangles=original[i:i+1],
                sourceBarycentrics=bary[i:i+1], sourceParents=parents[i:i+1],
                regionCells=np.array([cell]))
            try:
                certify_vertex_weights(xy[i:i+1], vertices[cells[[cell]]], local)
            except AssertionError:
                continue
            cell_ids[i] = cell
            break
        if cell_ids[i] < 0:
            raise ValueError(f'Discarded source parent {parents[i]} has no certified region cell')
    assert (cell_ids < len(cells)).all()
    construction['regionCells'] = cell_ids
    weights, proof = certify_vertex_weights(xy, vertices[cells[cell_ids]], construction)
    mapped = np.einsum('nij,njk->nik', weights, targets[cells[cell_ids]])
    for cell, declaration in verify_rank_one_declarations(family).items():
        selected = cell_ids == cell
        if selected.any():
            a, b = declaration['endpoints']
            mapped[selected] = a + (weights[selected] @ declaration['parameters'])[..., None] * (b - a)
    return mapped, cell_ids, proof


def lift(candidate, warp_path, full_pack, output, proof_path=None):
    if output.exists():
        raise FileExistsError(output)
    bindings = json.loads((candidate / 'bindings.json').read_text())
    proof_path = proof_path or candidate / 'independent-profile-review.json'
    proof = json.loads(proof_path.read_text())
    assert proof['status'] == 'attribute-and-continuous-span-contact-checks-passed'
    assert proof['provenanceSha256'] == sha(candidate / 'normalized-face-provenance.npz')
    control_path = Path(bindings['sourceBackup'])
    assert sha(control_path) == bindings['sourcePackSha256']
    assert sha(warp_path) == bindings['displayWarpSha256']
    header, control = pack(control_path)
    candidate_path = candidate / (header['map'] + '.height.bin.gz')
    assert sha(candidate_path) == proof['candidatePackSha256']
    assert sha(candidate / 'bindings.json') == proof['wallBindingsSha256']
    _, scene = pack(candidate_path)
    _, full = pack(full_pack)
    original_control_path = Path(bindings.get('originalSourcePack', str(control_path)))
    assert sha(original_control_path) == sha(control_path), 'Control backup and metadata source differ'
    field_path = original_control_path.parent / (header['map'] + '.tactical-ground.json.gz')
    assert sha(field_path) == header['tacticalGroundFieldSha256']
    assert sha(full_pack) == header['sourcePackSha256']
    field = GroundField(field_path)
    correspondence_path = original_control_path.parent / 'correspondence.npz'
    control_to_full = np.load(correspondence_path)['sourceFaces']
    assert len(control_to_full) == len(control['faces'])
    assert np.all((control_to_full >= 0) & (control_to_full < len(full['faces'])))
    parents = np.load(candidate / 'correspondence.npz')['sourceFaces']
    provenance = np.load(candidate / 'normalized-face-provenance.npz')
    ids = provenance['generatedFaceIds']
    generated_parents = parents[ids]
    discarded_values = provenance['discardedSourceFaces']
    discarded_parents = discarded_values.astype(np.int64)
    assert np.array_equal(discarded_values, discarded_parents)
    all_parents, lookup = np.unique(np.r_[generated_parents, discarded_parents], return_inverse=True)
    parent_triangles = control['vertices'][control['faces'][all_parents]].copy()
    parent_triangles[:, :, 2] += field.heights(parent_triangles[:, :, :2].reshape(-1, 2)).reshape(-1, 3)
    full_triangles = full['vertices'][full['faces'][control_to_full[all_parents]]]
    parent_bary, plane_error = triangle_barycentrics(parent_triangles, full_triangles)
    minimum_bary = float(parent_bary.min())
    assert plane_error < 1e-7 and minimum_bary > -1e-7, (plane_error, minimum_bary)
    # Keep source Z from the independently recovered source triangle coordinates,
    # rather than replacing it with a rounded plane or a new ground estimate.
    generated_bary = np.einsum('nij,njk->nik', provenance['generatedBarycentrics'], parent_bary[lookup[:len(ids)]])
    discarded_bary = np.einsum('nij,njk->nik', provenance['discardedBarycentrics'], parent_bary[lookup[len(ids):]])
    # Affine evaluation preserves exactly constant source coordinates, unlike
    # a three-vertex weighted sum whose weights can add to 1 plus rounding.
    generated_triangles = full_triangles[lookup[:len(ids)]]
    discarded_triangles = full_triangles[lookup[len(ids):]]
    generated_source = generated_triangles[:, :1] + np.einsum(
        'nij,njk->nik', generated_bary[:, :, 1:], generated_triangles[:, 1:] - generated_triangles[:, :1])
    discarded_source = discarded_triangles[:, :1] + np.einsum(
        'nij,njk->nik', discarded_bary[:, :, 1:], discarded_triangles[:, 1:] - discarded_triangles[:, :1])
    absolute_triangles = scene['vertices'][scene['faces'][ids]].copy()
    absolute_triangles[:, :, 2] = generated_source[:, :, 2]
    warp = json.loads(gzip.decompress(warp_path.read_bytes()))
    matrix = np.column_stack((warp['projection']['axisU'], warp['projection']['axisV']))
    origin = np.array(warp['projection']['origin'])
    discarded_profiles = np.full((len(discarded_parents), 3, 2), np.nan)
    discarded_display = np.full((len(discarded_parents), 3, 3), np.nan)
    discarded_region_cells = np.full(len(discarded_parents), -1, dtype=np.int64)
    discarded_original = control['vertices'][control['faces'][discarded_parents]]
    discarded_control = reconstruct_source_points(provenance['discardedBarycentrics'], discarded_original)
    restored = []
    for family in bindings['families']:
        mask = provenance['discardedEdges'] == family['edge']
        if not mask.any():
            continue
        if family.get('mappingType') == 'piecewise-affine-region-v1':
            xy, region_cells, containment = map_discarded_region(family,
                discarded_original[mask], provenance['discardedBarycentrics'][mask],
                provenance['discardedRegionCells'][mask], matrix, origin, discarded_parents[mask],
                dict(sourcePack=sha(control_path), provenance=sha(candidate / 'normalized-face-provenance.npz'),
                     bindings=sha(candidate / 'bindings.json'), sourceProfileProof=sha(proof_path)))
            displayed = np.concatenate((xy, discarded_source[mask, :, 2:3]), axis=2)
            discarded_display[mask] = displayed
            discarded_region_cells[mask] = region_cells
            cross = np.cross(displayed[:, 1] - displayed[:, 0], displayed[:, 2] - displayed[:, 0])
            positive = np.any(cross != 0, axis=1)
            restored.append(dict(edge=family['edge'], mappingType=family['mappingType'],
                checked=int(mask.sum()), sourceWorldPositiveAreaFragments=int(positive.sum()),
                sourceContainment=containment,
                limitation='All fragments retained, including numerical-scale and zero-area pieces. No exact degeneracy classification or compact compilation claim.'))
            continue
        o, t, _ = profile_frame(family, 'source')
        # Preserve the original normalization/clamp coordinates; source-plane
        # reconstruction supplies Z only, not a new authored XY registration.
        xy = discarded_control[mask, :, :2] @ matrix.T + origin
        along = (xy - o) @ t
        lo, hi = family['sourceAlong']
        target_lo, target_hi = family['targetAlong']
        target = target_lo + np.clip((along - lo) / (hi - lo), 0, 1) * (target_hi - target_lo)
        profiles = np.stack((target, discarded_source[mask, :, 2]), axis=2)
        discarded_profiles[mask] = profiles
        target_origin, target_tangent, _ = profile_frame(family, 'target')
        discarded_display[mask, :, :2] = target_origin + target[:, :, None] * target_tangent
        discarded_display[mask, :, 2] = discarded_source[mask, :, 2]
        areas = area(profiles)
        positive = areas > 0
        restored.append(dict(edge=family['edge'], checked=int(mask.sum()),
                             sourceWorldPositiveAreaFragments=int(positive.sum()),
                             positiveAreaAtOrBelow1e10=int(((areas > 0) & (areas <= 1e-10)).sum()),
                             maximumAreaSvgMeters=float(areas.max(initial=0))))
    masks = scene['faceMasks'][ids]
    discarded_masks = control['faceMasks'][discarded_parents]
    discarded_uvs = np.full((len(discarded_parents), 3, 2), np.nan)
    discarded_materials = np.full(len(discarded_parents), -1, dtype=np.int32)
    for i in np.flatnonzero(discarded_masks >= 0):
        discarded_uvs[i] = provenance['discardedBarycentrics'][i] @ control['maskedUvs'][discarded_masks[i]]
        discarded_materials[i] = control['maskedMaterials'][discarded_masks[i]]
    source_data = dict(candidateFaceIds=ids, edges=provenance['generatedEdges'],
                      controlParents=generated_parents, fullSourceParents=control_to_full[generated_parents],
                      sourceBarycentrics=generated_bary, triangles=absolute_triangles,
                      discardedControlParents=discarded_parents, discardedEdges=provenance['discardedEdges'],
                      discardedFullSourceParents=control_to_full[discarded_parents],
                      discardedControlBarycentrics=provenance['discardedBarycentrics'],
                      discardedSourceTriangles=discarded_source,
                      discardedFaceMasks=discarded_masks, discardedMaskedUvs=discarded_uvs,
                      discardedMaskedMaterials=discarded_materials,
                      discardedSourceBarycentrics=discarded_bary, discardedAbsoluteProfiles=discarded_profiles,
                      discardedAbsoluteDisplayTriangles=discarded_display,
                      discardedDeclaredRegionCells=discarded_region_cells,
                      faceMasks=masks, maskedUvs=scene['maskedUvs'], maskedMaterials=scene['maskedMaterials'])
    report = dict(scope=__doc__, map=header['map'], candidatePackSha256=sha(candidate_path),
                  fullSourcePackSha256=sha(full_pack), controlPackSha256=sha(control_path),
                  groundFieldSha256=sha(field_path), displayWarpSha256=sha(warp_path),
                  controlCorrespondenceSha256=sha(correspondence_path),
                  scriptSha256=sha(Path(__file__)), controlParents=len(all_parents),
                  formatVersion=2, sourceProfileProofSha256=sha(proof_path),
                  regionMappingVerifierSha256=sha(Path(__file__).with_name('verify_region_mapping.py')),
                  preciseContainmentSha256=sha(Path(__file__).with_name('precise_region_containment.py')),
                  generatedFragments=len(ids), maximumSourcePlaneErrorMeters=plane_error,
                  minimumSourceBarycentric=minimum_bary, discardedFragmentReview=restored,
                  productionMutation=False, floorPolicyCertified=False,
                  limitations=['This contains reviewed generated fragments, not the whole map.',
                               'Discarded positive-area profiles must be restored before source-world compilation.',
                               'No visibility query or performance claim follows from this source-coordinate proof.'])
    output.mkdir(parents=True)
    np.savez_compressed(output / 'source-world-fragments.npz', **source_data)
    report['dataSha256'] = sha(output / 'source-world-fragments.npz')
    (output / 'report.json').write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(report, indent=2))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('candidate', 'warp', 'full_pack', 'output'):
        parser.add_argument(name, type=Path)
    parser.add_argument('--proof', type=Path)
    args = parser.parse_args()
    lift(args.candidate, args.warp, args.full_pack, args.output, args.proof)

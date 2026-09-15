"""Independently check authored wall placement and retained source attributes.

This verifies the bounded normalization data, not the provisional floor policy
or gameplay. Pixel contact and preserved sightlines need separate checks.
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
from verify_region_mapping import declared_mapping, verify_region_fragments
from exact_source_partition import prove_partition


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def reconstruct_source_points(weights, triangles):
    """Interpolate local edge offsets to avoid adding absolute coordinates three times."""
    base = triangles[:, :1]
    return base + np.einsum('nij,njk->nik', weights[:, :, 1:], triangles[:, 1:] - base)


def profile_frame(family, role):
    """Read frames independently of the compiler's coordinate helpers."""
    assert ('sourceFrame' in family) == ('targetFrame' in family), 'Both wall frames are required'
    key = role + 'Frame'
    if key in family:
        value = family[key]
        origin, tangent, normal = (np.array(value[k], dtype=float) for k in ('origin', 'tangent', 'normal'))
        assert all(v.shape == (2,) and np.isfinite(v).all() for v in (origin, tangent, normal))
        basis = np.column_stack((tangent, normal))
        np.testing.assert_allclose(basis.T @ basis, np.eye(2), atol=1e-10, rtol=0)
        assert abs(np.linalg.det(basis) - 1) < 1e-10
        return origin, tangent, normal
    axis = family['axis']
    assert axis in (0, 1)
    tangent = np.eye(2)[axis]
    normal = np.array([-tangent[1], tangent[0]])
    origin = np.zeros(2)
    if role == 'target':
        origin[1 - axis] = family['fixed']
    return origin, tangent, normal


def verify_source_partition(parent_ids, barycentrics, removed):
    """Check coverage and overlap independently in each source triangle."""
    assert set(parent_ids.tolist()) == set(removed)
    reference = shapely.Polygon([(0, 0), (1, 0), (0, 1)])
    polygons = shapely.polygons(barycentrics[:, :, 1:])
    maximum_missing = maximum_overlap = 0.
    exact_reviews = []
    order = np.argsort(parent_ids)
    starts = np.r_[0, np.flatnonzero(np.diff(parent_ids[order])) + 1, len(order)]
    for lo, hi in zip(starts[:-1], starts[1:]):
        parts = polygons[order[lo:hi]]
        geos_exception = None
        try:
            union = shapely.union_all(parts)
            missing = float(reference.symmetric_difference(union).area) * 2
            overlap = max(0., float(shapely.area(parts).sum() - union.area)) * 2
        except shapely.errors.GEOSException as error:
            geos_exception = str(error)
            missing = overlap = None
        if geos_exception is not None or not (missing < 1e-9 and overlap < 1e-9):
            # Near-coincident clipped edges can destabilize GEOS union. Check
            # the stored coordinates as exact rationals before rejecting them.
            # No snapping or geometry change is allowed in this fallback.
            exact = prove_partition(barycentrics[order[lo:hi]])
            parent = int(parent_ids[order[lo]])
            assert exact['passed'], (parent, missing, overlap, exact)
            exact_reviews.append(dict(controlParent=parent,
                                      geosRelativeMissing=missing,
                                      geosRelativeOverlap=overlap,
                                      geosException=geos_exception, exact=exact))
            missing = exact['relativeSymmetricDifferenceUpperBound']['decimal']
            overlap = exact['relativeOverlapUpperBound']['decimal']
        maximum_missing = max(maximum_missing, missing)
        maximum_overlap = max(maximum_overlap, overlap)
    return dict(sourceFaces=len(removed), maximumRelativeCoverageError=maximum_missing,
                maximumRelativeOverlap=maximum_overlap,
                exactRationalFallbacks=exact_reviews)


def verify(folder, warp_path, report_path=None):
    if report_path is not None and report_path.exists():
        raise FileExistsError(report_path)
    proof = json.loads((folder / 'bindings.json').read_text())
    source_path = Path(proof['sourceBackup'])
    assert sha(source_path) == proof['sourcePackSha256']
    assert sha(warp_path) == proof['displayWarpSha256']
    source_header, source = pack(source_path)
    candidate_path = folder / (source_header['map'] + '.height.bin.gz')
    header, candidate = pack(candidate_path)
    parents = np.load(folder / 'correspondence.npz')['sourceFaces']
    provenance = np.load(folder / 'normalized-face-provenance.npz')
    ids = provenance['generatedFaceIds'].astype(int)
    bary = provenance['generatedBarycentrics']
    edges = provenance['generatedEdges']
    assert len(np.unique(ids)) == len(ids)
    assert bary.shape == (len(ids), 3, 3)
    assert np.isfinite(bary).all() and bary.min() >= -1e-10
    assert np.max(abs(bary.sum(axis=2) - 1)) < 1e-10
    original = source['vertices'][source['faces'][parents[ids]]]
    expected = reconstruct_source_points(bary, original)
    actual = candidate['vertices'][candidate['faces'][ids]]
    z_error = float(abs(expected[:, :, 2] - actual[:, :, 2]).max(initial=0))
    outside = edges < 0
    outside_error = float(abs(expected[outside] - actual[outside]).max(initial=0))
    assert z_error < 1e-10 and outside_error < 1e-10

    # Check every untouched face by coordinates, since packing reorders faces
    # and deduplicates vertices. No tolerance is needed for unchanged data.
    untouched = np.ones(len(parents), dtype=bool)
    untouched[ids] = False
    remaining = np.flatnonzero(untouched)
    assert np.unique(parents[remaining]).size == len(remaining)
    assert not np.intersect1d(parents[remaining], proof['removedControlFaces']).size
    assert len(remaining) == proof['unchangedOriginalFaces']
    for start in range(0, len(remaining), 100000):
        chunk = remaining[start:start + 100000]
        np.testing.assert_array_equal(candidate['vertices'][candidate['faces'][chunk]],
                                      source['vertices'][source['faces'][parents[chunk]]])
        np.testing.assert_array_equal(candidate['faceMasks'][chunk], source['faceMasks'][parents[chunk]])

    old_masks, new_masks = source['faceMasks'][parents[ids]], candidate['faceMasks'][ids]
    np.testing.assert_array_equal(old_masks < 0, new_masks < 0)
    masked = old_masks >= 0
    uv_error = 0.
    if masked.any():
        uv_expected = np.einsum('nij,njk->nik', bary[masked], source['maskedUvs'][old_masks[masked]])
        uv_error = float(abs(uv_expected - candidate['maskedUvs'][new_masks[masked]]).max())
        assert uv_error < 1e-10
        np.testing.assert_array_equal(source['maskedMaterials'][old_masks[masked]],
                                      candidate['maskedMaterials'][new_masks[masked]])
    assert header['materials'] == source_header['materials']

    warp = json.loads(gzip.decompress(warp_path.read_bytes()))
    matrix = np.column_stack((warp['projection']['axisU'], warp['projection']['axisV']))
    origin = np.array(warp['projection']['origin'])
    partition_review = None
    if 'discardedSourceFaces' in provenance:
        discarded_parents = provenance['discardedSourceFaces'].astype(int)
        discarded_bary = provenance['discardedBarycentrics']
        assert discarded_bary.shape == (len(discarded_parents), 3, 3)
        assert np.isfinite(discarded_bary).all() and discarded_bary.min(initial=0) >= -1e-10
        assert abs(discarded_bary.sum(axis=2) - 1).max(initial=0) < 1e-10
        partition_review = verify_source_partition(
            np.r_[parents[ids], discarded_parents], np.concatenate((bary, discarded_bary)),
            proof['removedControlFaces'])
        discarded_source = source['vertices'][source['faces'][discarded_parents]]
        discarded_xyz = reconstruct_source_points(discarded_bary, discarded_source)
        discarded_svg = discarded_xyz[:, :, :2] @ matrix.T + origin
        families = {family['edge']: family for family in proof['families']}
        maximum_discarded_span = 0.
        maximum_discarded_profile_area = 0.
        maximum_discarded_outside_area = 0.
        maximum_discarded_region_area = 0.
        discarded_region_containment = []
        for edge in np.unique(provenance['discardedEdges']):
            selected_discarded = provenance['discardedEdges'] == edge
            if edge == -1:
                outside_xyz = discarded_xyz[selected_discarded]
                area = np.linalg.norm(np.cross(outside_xyz[:, 1] - outside_xyz[:, 0],
                                               outside_xyz[:, 2] - outside_xyz[:, 0]), axis=1) / 2
                maximum_discarded_outside_area = float(area.max(initial=0))
                assert maximum_discarded_outside_area < 1e-12, 'discarded nondegenerate outside fragment'
                continue
            family = families[int(edge)]
            if family.get('mappingType') == 'piecewise-affine-region-v1':
                region_cells = provenance['discardedRegionCells'][selected_discarded]
                mapped, _ = declared_mapping(family, discarded_svg[selected_discarded], region_cells,
                    source_construction=dict(originalNativeTriangles=discarded_source[selected_discarded],
                        sourceBarycentrics=discarded_bary[selected_discarded],projectionMatrix=matrix,projectionOrigin=origin,
                        sourceParents=discarded_parents[selected_discarded],regionCells=region_cells,
                        inputHashes=dict(sourcePack=sha(source_path),provenance=sha(folder/'normalized-face-provenance.npz'),
                            displayWarp=sha(warp_path),bindings=sha(folder/'bindings.json'))),
                    containment_records=discarded_region_containment)
                xyz = np.concatenate((mapped, discarded_xyz[selected_discarded, :, 2:3]), axis=2)
                region_area = float(np.linalg.norm(np.cross(xyz[:, 1]-xyz[:, 0],
                                                           xyz[:, 2]-xyz[:, 0]), axis=1).max(initial=0)) / 2
                assert region_area < 1e-10, (int(edge), 'discarded noncollapsed region fragment', region_area)
                maximum_discarded_region_area = max(maximum_discarded_region_area, region_area)
                continue
            lower, upper = family['sourceAlong']
            t0, t1 = family['targetAlong']
            frame_origin, tangent, _ = profile_frame(family, 'source')
            source_along = (discarded_svg[selected_discarded] - frame_origin) @ tangent
            for boundary in (lower, upper):
                straddles = (source_along.min(axis=1) < boundary - 1e-8) & (
                    source_along.max(axis=1) > boundary + 1e-8)
                assert not straddles.any(), (int(edge), 'discarded fragment crosses clamp kink')
            along = t0 + np.clip((source_along - lower) /
                                 (upper - lower), 0, 1) * (t1 - t0)
            span = float(np.ptp(along, axis=1).max(initial=0))
            # Depth ledges can retain their full along-wall extent while
            # collapsing to a horizontal line. Check area in along/height.
            profile = np.stack((along, discarded_xyz[selected_discarded, :, 2]), axis=2)
            ab, ac = profile[:, 1] - profile[:, 0], profile[:, 2] - profile[:, 0]
            profile_area = float(abs(ab[:, 0] * ac[:, 1] - ab[:, 1] * ac[:, 0]).max(initial=0)) / 2
            assert profile_area < 1e-10, (int(edge), 'discarded noncollapsed source profile', profile_area)
            maximum_discarded_profile_area = max(maximum_discarded_profile_area, profile_area)
            maximum_discarded_span = max(maximum_discarded_span, span)
        partition_review.update(discardedFragments=len(discarded_parents),
                                discardedRegionContainment=discarded_region_containment,
                                maximumDiscardedAlongSpanSvg=maximum_discarded_span,
                                maximumDiscardedProfileAreaSvgMeters=maximum_discarded_profile_area,
                                maximumDiscardedRegionAreaSvgZ=maximum_discarded_region_area,
                                maximumDiscardedOutsideAreaSquareMeters=maximum_discarded_outside_area)
    source_svg = np.array(warp['sourceNativeMeters']).reshape(-1, 2) @ matrix.T + origin
    target_svg = np.array(warp['targetAttackSvg']).reshape(-1, 2)
    cells = np.array(warp['triangles']).reshape(-1, 3)
    forward = explicit_warp(source_svg, target_svg - source_svg, cells)
    active = np.any(np.linalg.norm(target_svg[cells] - source_svg[cells], axis=2) > 0, axis=1)
    active_tree = shapely.STRtree(shapely.polygons(source_svg[cells[active]]))
    cell_polygons = shapely.polygons(source_svg[cells])
    cell_tree = shapely.STRtree(cell_polygons)
    # Interior samples detect inverse mapping only at vertices when a wall
    # crosses display cells. Also report any active cell intersection, which
    # requires a separate cell-containment proof for continuous equivalence.
    probes = np.array([[i, j, 8-i-j] for i in range(9) for j in range(9-i)]) / 8.
    records = []
    for family in proof['families']:
        if family.get('mappingType') == 'piecewise-affine-region-v1':
            selected = edges == family['edge']
            assert selected.any(), family['edge']
            records.append(verify_region_fragments(family,
                expected[selected, :, :2] @ matrix.T + origin,
                actual[selected, :, :2] @ matrix.T + origin,
                provenance['generatedRegionCells'][selected].astype(int),
                provenance['generatedWarpCells'][selected].astype(int), forward, probes,
                source_construction=dict(originalNativeTriangles=original[selected],
                    sourceBarycentrics=bary[selected],projectionMatrix=matrix,projectionOrigin=origin,
                    sourceParents=parents[ids][selected],regionCells=provenance['generatedRegionCells'][selected],
                    inputHashes=dict(sourcePack=sha(source_path),provenance=sha(folder/'normalized-face-provenance.npz'),
                        displayWarp=sha(warp_path),bindings=sha(folder/'bindings.json')))))
            continue
        source_frame_origin, source_tangent, _ = profile_frame(family, 'source')
        target_frame_origin, target_tangent, target_normal = profile_frame(family, 'target')
        selected = edges == family['edge']
        triangles = actual[selected]
        assert len(triangles), family['edge']
        xy = triangles[:, :, :2] @ matrix.T + origin
        positions = np.einsum('ij,njk->nik', probes, xy)
        displayed = forward.apply(positions.reshape(-1, 2)).reshape(len(xy), len(probes), 2)
        source_positions = np.einsum('ij,njk->nik', probes, expected[selected, :, :2]) @ matrix.T + origin
        source_lower, source_upper = family['sourceAlong']
        target_lower, target_upper = family['targetAlong']
        expected_along = target_lower + np.clip(
            ((source_positions - source_frame_origin) @ source_tangent - source_lower) / (source_upper - source_lower),
            0, 1) * (target_upper - target_lower)
        actual_along = (displayed - target_frame_origin) @ target_tangent
        along_profile_error = float(abs(actual_along - expected_along).max())
        # Older diagnostic packs do not claim clamp-cell splitting. Keep that
        # limitation measurable; new packs carrying cell provenance must pass.
        if 'generatedWarpCells' in provenance:
            assert along_profile_error < 1e-7, (family['edge'], 'profile crosses clamp kink', along_profile_error)
            source_vertex_along = (expected[selected, :, :2] @ matrix.T + origin - source_frame_origin) @ source_tangent
            for boundary in (source_lower, source_upper):
                straddles = (source_vertex_along.min(axis=1) < boundary - 1e-8) & (
                    source_vertex_along.max(axis=1) > boundary + 1e-8)
                assert not straddles.any(), (family['edge'], 'unsplit clamp boundary', int(straddles.sum()))
            declared_cells = provenance['generatedWarpCells'][selected].astype(int)
            assert (declared_cells >= 0).all() and (declared_cells < len(cells)).all()
            transform = forward.tri.transform[declared_cells]
            uv = np.einsum('nij,nkj->nki', transform[:, :2], xy - transform[:, None, 2])
            cell_bary = np.concatenate((uv, 1 - uv.sum(axis=2, keepdims=True)), axis=2)
            assert cell_bary.min() >= -1e-8, (family['edge'], 'fragment crosses declared display cell', float(cell_bary.min()))
        error = float(abs((displayed - target_frame_origin) @ target_normal).max())
        assert error < 1e-7, (family['edge'], error)
        along = actual_along
        lower, upper = sorted(family['targetAlong'])
        overrun = max(0., float(lower - along.min()), float(along.max() - upper))
        assert overrun < 1e-7, (family['edge'], 'extends beyond authored corner', overrun)
        # Each projected triangle is a wall segment, so use its furthest pair.
        spans = []
        for tri in xy:
            d = np.sum((tri[:, None] - tri[None]) ** 2, axis=2)
            a, b = np.unravel_index(d.argmax(), d.shape)
            spans.append(shapely.LineString([tri[a], tri[b]]))
        intersections = active_tree.query(spans, predicate='intersects')
        active_count = int(len(np.unique(intersections[0]))) if intersections.size else 0
        line_ids, cell_ids = cell_tree.query(spans, predicate='intersects')
        clipped = shapely.intersection(np.array(spans, dtype=object)[line_ids], cell_polygons[cell_ids])
        breakpoints = shapely.get_coordinates(clipped)
        assert len(breakpoints)
        # W is affine inside each cell. A linear coordinate reaches its extrema
        # at interval endpoints, so every line/cell breakpoint bounds the whole
        # displayed span, including regions between the sampled probes above.
        breakpoint_display = forward.apply(breakpoints)
        continuous_error = float(abs((breakpoint_display - target_frame_origin) @ target_normal).max())
        assert continuous_error < 1e-7, (family['edge'], 'display cell boundary', continuous_error)
        records.append(dict(svgEdge=family['edge'], generatedTriangles=len(triangles),
                            maximumSampledContactErrorSvg=error,
                            maximumContinuousSpanContactErrorSvg=continuous_error,
                            maximumSampledAlongProfileMappingErrorSvg=along_profile_error,
                            displayCellBreakpointsChecked=len(breakpoints),
                            maximumAuthoredSpanOverrunSvg=overrun,
                            trianglesIntersectingActiveWarpCells=active_count,
                            continuousIdentityWarpProof=active_count == 0))
    report = dict(status='attribute-and-continuous-span-contact-checks-passed',
                  scope=__doc__, sourcePackSha256=sha(source_path), candidatePackSha256=sha(candidate_path),
                  verifierSha256=sha(Path(__file__)), wallBindingsSha256=sha(folder / 'bindings.json'),
                  regionVerifierSha256=sha(Path(__file__).with_name('verify_region_mapping.py')),
                  preciseRegionContainmentSha256=sha(Path(__file__).with_name('precise_region_containment.py')),
                  sourceCoordinateCertificateVerifierSha256=sha(Path(__file__).with_name('verify_source_cell_coordinate_certificate.py')),
                  exactPartitionVerifierSha256=sha(Path(__file__).with_name('exact_source_partition.py')),
                  provenanceSha256=sha(folder / 'normalized-face-provenance.npz'),
                  generatedTriangles=len(ids), untouchedTriangles=len(remaining),
                  outsideFragments=int(outside.sum()), maximumHeightErrorMeters=z_error,
                  maximumOutsideFragmentCoordinateErrorMeters=outside_error,
                  maskedGeneratedTriangles=int(masked.sum()), maximumUvError=uv_error,
                  sourcePartition=partition_review,
                  families=records)
    (report_path or folder / 'independent-profile-review.json').write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(report, indent=2))
    return report


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('folder', type=Path)
    parser.add_argument('--warp', type=Path, required=True)
    parser.add_argument('--report', type=Path)
    args = parser.parse_args()
    verify(args.folder, args.warp, args.report)

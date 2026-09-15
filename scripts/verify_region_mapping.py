"""Independent checks for declared source-to-SVG attachment region mappings."""
from collections import Counter

import numpy as np
import shapely
from precise_region_containment import certify_vertex_weights


def region_arrays(family):
    source = np.asarray(family['sourceVerticesSvg'], dtype=float)
    target = np.asarray(family['targetVerticesSvg'], dtype=float)
    cells = np.asarray(family['triangles'], dtype=np.int64)
    assert source.ndim == 2 and source.shape[1] == 2 and target.shape == source.shape
    assert cells.ndim == 2 and cells.shape[1] == 3 and len(cells)
    assert np.isfinite(source).all() and np.isfinite(target).all()
    assert cells.min() >= 0 and cells.max() < len(source)
    return source, target, cells


def verify_rank_one_declarations(family):
    """Certify explicit line collapses without accepting an arbitrary small fold."""
    source, target, cells = region_arrays(family)
    mappings = {}
    for declaration in family.get('declaredRankOneMappings', []):
        endpoints = np.asarray(declaration['targetEndpointsSvg'], dtype=float)
        ids = np.asarray(declaration['targetEndpointVertexIds'], dtype=int)
        assert endpoints.shape == (2, 2) and ids.shape == (2,)
        assert (ids >= 0).all() and (ids < len(target)).all()
        np.testing.assert_array_equal(target[ids], endpoints)
        assert np.linalg.norm(endpoints[1] - endpoints[0]) > 0
        origin = np.asarray(declaration['sourceOriginSvg'], dtype=float)
        tangent = np.asarray(declaration['sourceTangent'], dtype=float)
        length = float(declaration['sourceLengthSvg'])
        assert origin.shape == tangent.shape == (2,) and np.isfinite(origin).all()
        assert np.isfinite(tangent).all() and abs(tangent @ tangent - 1) < 1e-12
        assert np.isfinite(length) and length > 0
        endpoint_arithmetic = float(declaration['sourceEndpointArithmeticSvg'])
        assert 0 <= endpoint_arithmetic <= 1e-10
        for entry in declaration['cells']:
            cell = int(entry['cell'])
            assert 0 <= cell < len(cells) and cell not in mappings
            parameters = np.asarray(entry['vertexParameters'], dtype=float)
            assert parameters.shape == (3,) and np.isfinite(parameters).all()
            assert (parameters >= 0).all() and (parameters <= 1).all()
            points = source[cells[cell]]
            along = (points - origin) @ tangent
            recovered = along / length
            recovered[abs(along) <= endpoint_arithmetic] = 0
            recovered[abs(along - length) <= endpoint_arithmetic] = 1
            error_bound = 32 * np.finfo(float).eps * max(1., float(abs(points).max()),
                                                       float(abs(origin).max())) / length
            assert abs(recovered - parameters).max() <= error_bound, 'Unproved line parameter'
            expected = endpoints[0] + parameters[:, None] * (endpoints[1] - endpoints[0])
            # This bound only covers evaluating the declared line, never a
            # geometric distance chosen to hide an off-line target or fold.
            bound = 4 * np.spacing(np.maximum(1., abs(expected)))
            residual = abs(target[cells[cell]] - expected)
            assert (residual <= bound).all(), 'Rank-one target deviates from declared line'
            mappings[cell] = dict(parameters=parameters, endpoints=endpoints,
                                  maximumStoredTargetResidualSvg=float(residual.max()))
    return mappings


def declared_mapping(family, points, cell_ids, source_construction=None, containment_records=None):
    source, target, cells = region_arrays(family)
    cell_ids = np.asarray(cell_ids, dtype=np.int64)
    assert len(points) == len(cell_ids)
    assert (cell_ids >= 0).all() and (cell_ids < len(cells)).all()
    tri = source[cells[cell_ids]]
    construction=dict(source_construction,family=family) if source_construction is not None else None
    weights,containment=certify_vertex_weights(points,tri,construction)
    minimum=containment['certifiedVertexMinimum']
    if containment_records is not None:
        containment_records.append(dict(svgEdge=family.get('edge'),**containment))
    target_tri=target[cells[cell_ids]]
    mapped=target_tri[:,:1]+np.einsum('nij,njk->nik',weights[:,:,1:],target_tri[:,1:]-target_tri[:,:1])
    for cell, declaration in verify_rank_one_declarations(family).items():
        selected = cell_ids == cell
        if selected.any():
            along = weights[selected] @ declaration['parameters']
            a, b = declaration['endpoints']
            mapped[selected] = a + along[..., None] * (b - a)
    return mapped, minimum


def verify_region_topology(family, forward):
    source, target, cells = region_arrays(family)
    triangles = source[cells]
    polygons = shapely.polygons(triangles)
    area = shapely.area(polygons)
    assert (area > 0).all(), 'Degenerate source region cell'
    union = shapely.union_all(polygons)
    overlap = float(area.sum() - union.area)
    assert abs(overlap) < 1e-8, ('Overlapping source region cells', overlap)
    signed = lambda tri: ((tri[:, 1, 0]-tri[:, 0, 0])*(tri[:, 2, 1]-tri[:, 0, 1])
                          -(tri[:, 1, 1]-tri[:, 0, 1])*(tri[:, 2, 0]-tri[:, 0, 0]))
    determinant = signed(target[cells]) / signed(triangles)
    rank_one = verify_rank_one_declarations(family)
    checked_determinant = determinant.copy()
    for cell in rank_one:
        checked_determinant[cell] = 0
    assert (checked_determinant >= -1e-12).all(), 'Region mapping folds a source cell'
    counts = Counter(tuple(sorted((int(a), int(b)))) for tri in cells
                     for a, b in zip(tri, np.roll(tri, -1)))
    assert max(counts.values()) <= 2, 'Nonmanifold region edge'
    boundary_edges = [edge for edge, count in counts.items() if count == 1]
    errors = []
    warp_polygons = shapely.polygons(forward.points[forward.tri.simplices])
    warp_tree = shapely.STRtree(warp_polygons)
    for a, b in boundary_edges:
        line = shapely.LineString(source[[a, b]])
        # Internal edges with duplicated vertex IDs or unsplit T-junctions
        # cannot masquerade as an identity outer boundary.
        assert shapely.difference(line, union.boundary).length < 1e-8
        intersections = shapely.intersection(line, warp_polygons[warp_tree.query(line)])
        assert shapely.difference(line, shapely.union_all(intersections)).length < 1e-8, 'Region outer edge escapes display W'
        points = shapely.get_coordinates(intersections)
        assert len(points), 'Region outer edge is outside display W'
        direction = source[b] - source[a]
        t = (points-source[a]) @ direction / (direction @ direction)
        expected = forward.apply(points)
        actual = target[a] + t[:, None] * (target[b]-target[a])
        errors.extend(np.linalg.norm(actual-expected, axis=1).tolist())
    maximum = max(errors, default=0.)
    assert maximum < 1e-7, ('Region outer edge does not preserve displayed identity', maximum)
    return dict(sourceCells=len(cells), collapsedTargetCells=int((determinant == 0).sum()),
                minimumSignedAreaRatio=float(determinant.min()),
                declaredRankOneCells=len(rank_one),
                declaredRankOneStoredResiduals=[dict(cell=cell, signedAreaRatio=float(determinant[cell]),
                    maximumStoredTargetResidualSvg=value['maximumStoredTargetResidualSvg'])
                    for cell, value in rank_one.items()],
                sourceCellOverlapSvgSquared=overlap, identityBoundaryEdges=len(boundary_edges),
                maximumBoundaryDisplayErrorSvg=maximum)


def verify_region_fragments(family, source_points, actual_xy, source_cells,
                            display_cells, forward, probes, source_construction=None):
    topology = verify_region_topology(family, forward)
    source,target,cells=region_arrays(family)
    source_points=np.asarray(source_points,dtype=float)
    actual_xy=np.asarray(actual_xy,dtype=float)
    source_cells=np.asarray(source_cells,dtype=np.int64)
    display_cells=np.asarray(display_cells,dtype=np.int64)
    probes=np.asarray(probes,dtype=float)
    assert source_points.shape==actual_xy.shape==(len(source_cells),3,2)
    assert (source_cells>=0).all() and (source_cells<len(cells)).all()
    construction=dict(source_construction,family=family) if source_construction is not None else None
    vertex_weights,containment=certify_vertex_weights(source_points,source[cells[source_cells]],construction)
    assert np.isfinite(probes).all() and probes.min()>=0 and np.max(abs(probes.sum(1)-1))<1e-12
    # Vertex errors bound an affine fragment. A caller's optional interior
    # samples must never replace those required endpoint checks.
    probes=np.concatenate((np.eye(3),probes),axis=0)
    weights=np.einsum('ij,njk->nik',probes,vertex_weights)
    target_tri=target[cells[source_cells]]
    expected=target_tri[:,:1]+np.einsum('nij,njk->nik',weights[:,:,1:],target_tri[:,1:]-target_tri[:,:1])
    for cell,declaration in verify_rank_one_declarations(family).items():
        selected=source_cells==cell
        if selected.any():
            along=weights[selected]@declaration['parameters'];a,b=declaration['endpoints'];expected[selected]=a+along[...,None]*(b-a)
    minimum=containment['certifiedVertexMinimum']
    actual_samples=actual_xy[:,:1]+np.einsum('ij,njk->nik',probes[:,1:],actual_xy[:,1:]-actual_xy[:,:1])
    displayed = forward.apply(actual_samples.reshape(-1, 2))
    displayed = displayed.reshape(expected.shape)
    error = float(np.linalg.norm(displayed-expected, axis=2).max(initial=0))
    bounded_error=error+containment['maximumMappedExtensionErrorSvg']
    assert bounded_error < 1e-7, ('Region mapping differs from its declared continuous field', bounded_error)
    # Both source mapping and display W must be affine over each fragment;
    # checking samples alone would miss a narrow intervening kink.
    # Certified source vertex weights already prove containment of the entire
    # affine fragment. Re-solving rounded dense SVG samples would add error.
    assert (display_cells >= 0).all() and (display_cells < len(forward.tri.simplices)).all()
    transform = forward.tri.transform[display_cells]
    uv = np.einsum('nij,nkj->nki', transform[:, :2], actual_xy-transform[:, None, 2])
    weights = np.concatenate((uv, 1-uv.sum(axis=2, keepdims=True)), axis=2)
    assert weights.min(initial=0) >= -1e-8, 'Region fragment crosses display W cell'
    return dict(svgEdge=family['edge'], mappingType=family['mappingType'],
                generatedTriangles=len(actual_xy), maximumRegionMappingErrorSvg=error,
                minimumSourceCellBarycentricWeight=minimum, topology=topology,
                sourceContainment=containment,
                maximumContinuousFieldErrorSvg=bounded_error,
                continuousAffineCellProof=containment['coordinateCertifiedFragments']==0,
                boundedCoordinateExtensionProof=containment['coordinateCertifiedFragments']>0)

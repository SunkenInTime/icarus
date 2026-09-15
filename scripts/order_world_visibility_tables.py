"""Put nearby vertices and edges together to improve lossless delta compression.

Only table indices change. Each layer retains its exact ordered sequence of
directed physical segments, including the offline BVH order and duplicate
coordinates where present. Runtime decoding needs no additional operation.
"""
import numpy as np


def spatial_order(points):
    points = np.asarray(points, dtype=np.int64).reshape(-1, 2)
    if not len(points):
        return np.empty(0, dtype=np.int64)
    shifted = points - points.min(axis=0)
    if shifted.max() >= 1 << 32:
        raise ValueError('Spatial table ordering requires int32 coordinate spans.')

    def spread(values):
        values = values.astype(np.uint64)
        for shift, mask in ((16, 0x0000FFFF0000FFFF), (8, 0x00FF00FF00FF00FF),
                            (4, 0x0F0F0F0F0F0F0F0F), (2, 0x3333333333333333),
                            (1, 0x5555555555555555)):
            values = (values | (values << np.uint64(shift))) & np.uint64(mask)
        return values

    keys = spread(shifted[:, 0]) | (spread(shifted[:, 1]) << np.uint64(1))
    return np.argsort(keys, kind='stable')


def order_tables(data):
    vertices = np.asarray(data['vertices'], dtype=np.int64).reshape(-1, 2)
    edges = np.asarray(data['edges'], dtype=np.int64).reshape(-1, 2)
    vertex_order = spatial_order(vertices)
    remap = np.empty(len(vertex_order), dtype=np.int64)
    remap[vertex_order] = np.arange(len(vertex_order))
    vertices = vertices[vertex_order]
    edges = remap[edges]
    # A rounded key affects only sort order, never the stored endpoints.
    midpoints = vertices[edges].sum(axis=1) // 2
    edge_order = spatial_order(midpoints)
    edge_remap = np.empty(len(edge_order), dtype=np.int64)
    edge_remap[edge_order] = np.arange(len(edge_order))
    return {**data, 'vertices': vertices.reshape(-1).tolist(),
            'edges': edges[edge_order].reshape(-1).tolist(),
            'layers': [{**layer, 'edges': edge_remap[np.asarray(layer['edges'], dtype=np.int64)].tolist()}
                       for layer in data['layers']]}

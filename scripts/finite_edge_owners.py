"""Bounded exact-topology cache for immutable finite-cell edge ownership."""
from collections import OrderedDict
from types import MappingProxyType
import sys

import numpy as np

MAX_ENTRIES = 8
MAX_BYTES = 32 * 1024 * 1024
_cache = OrderedDict()
_bytes = 0
_hits = 0
_misses = 0


def edge_owners(triangles):
    global _bytes, _hits, _misses
    triangles = np.asarray(triangles)
    if triangles.ndim != 2 or triangles.shape[1] != 3 or triangles.dtype.kind not in 'iu':
        raise ValueError('Triangle ownership requires a numeric integer Nx3 topology')
    # Full bytes are the identity, not a hash or the mutable ndarray address.
    key = (triangles.shape, triangles.dtype.str, triangles.tobytes(order='C'))
    if key in _cache:
        _hits += 1
        owners, size = _cache.pop(key)
        _cache[key] = (owners, size)
        return owners
    _misses += 1
    owners = {}
    for cell, ids in enumerate(triangles):
        for a, b in zip(ids, np.roll(ids, -1)):
            edge = tuple(sorted((int(a), int(b))))
            owners[edge] = min(cell, owners.get(edge, cell))
    # This overcounts shared Python integers, providing a conservative bound
    # on retained table payload. Dictionary/cache fixed overhead is < 64 KiB.
    size = sys.getsizeof(owners) + sum(sys.getsizeof(k) +
        sum(sys.getsizeof(x) for x in k) + sys.getsizeof(v)
        for k, v in owners.items()) + sys.getsizeof(key[2]) + 1024
    result = MappingProxyType(owners)
    if size <= MAX_BYTES:
        while _cache and (len(_cache) >= MAX_ENTRIES or _bytes + size > MAX_BYTES):
            _, (_, removed_size) = _cache.popitem(last=False)
            _bytes -= removed_size
        _cache[key] = (result, size)
        _bytes += size
    return result


def clear_cache():
    global _bytes, _hits, _misses
    _cache.clear()
    _bytes = _hits = _misses = 0


def cache_info():
    return dict(entries=len(_cache), retainedPayloadUpperBoundBytes=_bytes,
        hits=_hits, misses=_misses, maximumEntries=MAX_ENTRIES,
        maximumPayloadBytes=MAX_BYTES)

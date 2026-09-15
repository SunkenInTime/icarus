"""Exact entry-local floor choices along a fixed support portal.

Candidate footprints must already be constant over this portal and the incoming
ground must be a known affine source plane. Gaps and detached rays are separate.
The output can replace runtime nav/source-height ranking with a short lookup.
"""
import itertools
import numpy as np


def choose(point, previous, sources, nav, terrain=None, raised=None, raised_origin=False, step=.35):
    sources = np.asarray(sources, dtype=float).reshape(-1, 3)
    nav = np.asarray(nav, dtype=float).reshape(-1, 3)
    terrain = np.zeros(len(sources), dtype=bool) if terrain is None else np.asarray(terrain, dtype=bool)
    raised = np.zeros(len(sources), dtype=bool) if raised is None else np.asarray(raised, dtype=bool)
    p = np.r_[point, 1.]
    heights, before = sources @ p, previous @ p
    errors = abs(heights - before)
    eligible = (raised & (errors <= 1e-5)) if raised_origin else ~raised
    close = np.flatnonzero(eligible & (errors <= .35))
    if len(nav):
        nav_heights = nav @ p
        hint = int(np.argmin(abs(nav_heights - before)))
        hint_errors = abs(heights - nav_heights[hint])
        real = np.flatnonzero(eligible & (hint_errors <= .35) & (errors <= step + 1e-6))
        if len(real):
            close = real[hint_errors[real] <= hint_errors[real].min() + 1e-5]
            if len(close) > 1:
                gradients = np.linalg.norm(sources[close, :2] - nav[hint, :2], axis=1)
                close = close[gradients <= gradients.min() + 1e-8]
    real_terrain = np.flatnonzero(eligible & terrain & (errors <= step + 1e-6))
    if len(real_terrain):
        close = real_terrain[heights[real_terrain] >= heights[real_terrain].max() - 1e-5]
    if not len(close):
        close = np.flatnonzero(eligible)
    close = close[errors[close] <= step + 1e-6]
    if not len(close):
        return []
    return close[errors[close] <= errors[close].min() + 1e-5].tolist()


def compile_portal_table(endpoints, previous, sources, nav, terrain=None, raised=None, raised_origin=False, step=.35):
    """Return exact constant candidate sets, before direction-dependent final ties.

    A final equal-height/equal-nav-gradient tie can still depend on ray direction
    through the existing least-changing rule. Retain that small candidate set,
    rather than incorrectly labeling one surface as the unique destination.
    """
    endpoints = np.asarray(endpoints, dtype=float)
    previous = np.asarray(previous, dtype=float)
    sources = np.asarray(sources, dtype=float).reshape(-1, 3)
    nav = np.asarray(nav, dtype=float).reshape(-1, 3)
    lines = []
    def offsets(line, values):
        for value in values:
            lines.append(line + [0, 0, value])
    for source in sources:
        offsets(source-previous, [-step-1e-6, -.35, -1e-5, 0, 1e-5, .35, step+1e-6])
        for hint in nav:
            offsets(source-hint, [-.35, 0, .35])
    for a, b in itertools.combinations(nav, 2):
        lines.extend((a-b, a+b-2*previous))
    for a, b in itertools.combinations(sources, 2):
        offsets(a-b, [-1e-5, 0, 1e-5])
        for reference in itertools.chain([previous], nav):
            offsets(a+b-2*reference, [-1e-5, 0, 1e-5])
    events = [0., 1.]
    if lines:
        values = np.asarray(lines) @ np.c_[endpoints, np.ones(2)].T
        slopes = values[:, 1] - values[:, 0]
        crossing = np.flatnonzero(slopes != 0)
        t = -values[crossing, 0] / slopes[crossing]
        events.extend(t[(t > 0) & (t < 1)])
    events = np.unique(events)
    intervals = []
    for lo, hi in zip(events[:-1], events[1:]):
        point = endpoints[0] + (lo+hi)/2 * (endpoints[1]-endpoints[0])
        candidates = choose(point, previous, sources, nav, terrain, raised, raised_origin, step)
        if intervals and intervals[-1]['candidates'] == candidates:
            intervals[-1]['hi'] = float(hi)
        else:
            intervals.append(dict(lo=float(lo), hi=float(hi), candidates=candidates))
    knots = [dict(at=float(t), candidates=choose(endpoints[0]+t*(endpoints[1]-endpoints[0]),
                  previous, sources, nav, terrain, raised, raised_origin, step)) for t in events]
    return dict(intervals=intervals, knots=knots,
                policy=dict(endpoints=endpoints.tolist(), previous=previous.tolist(), sources=sources.tolist(), nav=nav.tolist(),
                            terrain=None if terrain is None else np.asarray(terrain, dtype=bool).tolist(),
                            raised=None if raised is None else np.asarray(raised, dtype=bool).tolist(),
                            raised_origin=raised_origin, step=step))


def compile_portal(*args, **kwargs):
    """Interval-only view. Exact cuts require compile_portal_table/lookup_portal."""
    return compile_portal_table(*args, **kwargs)['intervals']


def lookup_portal(table, t):
    if not np.isfinite(t) or not 0 <= t <= 1:
        raise ValueError('Portal parameter must be finite and within [0,1]')
    knots = table['knots']
    positions = np.array([knot['at'] for knot in knots])
    insertion = int(np.searchsorted(positions, t))
    if insertion < len(knots) and positions[insertion] == t:
        return knots[insertion]['candidates']
    nearest = min([i for i in [insertion-1, insertion] if 0 <= i < len(knots)], key=lambda i: abs(positions[i]-t))
    # Adjacent representable inputs can round a threshold comparison
    # differently from its real-arithmetic side. Keep the original pointwise
    # policy for this explicit numerical boundary guard.
    if abs(positions[nearest]-t) <= 32*np.finfo(float).eps*max(1., abs(t)):
        policy = dict(table['policy'])
        endpoints = np.array(policy.pop('endpoints'))
        policy['previous'] = np.array(policy['previous'])
        return choose(endpoints[0]+t*(endpoints[1]-endpoints[0]), **policy)
    return next(row['candidates'] for row in table['intervals'] if row['lo'] < t < row['hi'])

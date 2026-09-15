"""Actual union of all SVG base fills, with their authored nonzero/evenodd rules."""
import xml.etree.ElementTree as ET

import numpy as np
from shapely import LineString, Polygon, union_all
from shapely.ops import polygonize
from svgpathtools import parse_path, Line, CubicBezier, QuadraticBezier


def flatten(segment, tolerance=1e-5, depth=0):
    if isinstance(segment, Line):
        return [segment.start, segment.end]
    if isinstance(segment, CubicBezier):
        controls = [segment.start, segment.control1, segment.control2, segment.end]
    elif isinstance(segment, QuadraticBezier):
        controls = [segment.start, segment.control, segment.end]
    else:
        raise ValueError('Unsupported receiver curve; an explicit error bound is required')
    a, b = segment.start, segment.end
    delta = b - a
    distances = []
    for point in controls:
        along = ((point - a).real * delta.real + (point - a).imag * delta.imag) / abs(delta) ** 2 if abs(delta) else 0
        nearest = a + delta * min(1., max(0., along))
        distances.append(abs(point - nearest))
    # A Bezier remains inside its control hull, so this is a spatial bound.
    if max(distances) <= tolerance:
        return [a, b]
    if depth >= 24:
        raise ValueError('Receiver curve did not meet the declared error bound')
    left, right = segment.split(.5)
    return flatten(left, tolerance, depth + 1)[:-1] + flatten(right, tolerance, depth + 1)


def winding(point, ring):
    x, y = point.x, point.y
    result = 0
    for a, b in zip(ring[:-1], ring[1:]):
        side = (b[0] - a[0]) * (y - a[1]) - (b[1] - a[1]) * (x - a[0])
        if a[1] <= y < b[1] and side > 0: result += 1
        elif b[1] <= y < a[1] and side < 0: result -= 1
    return result


def receiver_domain(path, tolerance_svg=1e-5):
    root = ET.parse(path).getroot()
    parents = {child: parent for parent in root.iter() for child in parent}
    filled = []
    for element in root.iter():
        if not element.tag.endswith('path') or element.get('fill', '').lower() != '#271406':
            continue
        ancestor = element
        while ancestor is not None:
            if 'transform' in ancestor.attrib or 'style' in ancestor.attrib:
                raise ValueError('Transformed/styled receiver requires explicit support')
            ancestor = parents.get(ancestor)
        rings = []
        for subpath in parse_path(element.get('d')).continuous_subpaths():
            values = []
            for segment in subpath:
                values.extend(flatten(segment, tolerance_svg)[:-1])
            values.append(subpath[-1].end)
            points = np.array([[p.real, p.imag] for p in values])
            if np.linalg.norm(points[-1] - points[0]) > 0:
                points = np.vstack((points, points[0]))
            rings.append(points)
        facets = polygonize(union_all([LineString(ring) for ring in rings]))
        evenodd = element.get('fill-rule', 'nonzero') == 'evenodd'
        for facet in facets:
            count = sum(winding(facet.representative_point(), ring) for ring in rings)
            if (abs(count) % 2 == 1) if evenodd else (count != 0):
                filled.append(facet)
    if not filled:
        raise ValueError('No visible SVG base fills')
    return union_all(filled)

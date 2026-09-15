"""Extract literal painted wall and receiver footprints from every map SVG."""

import argparse
import hashlib
import json
import math
import re
import xml.etree.ElementTree as ET
from pathlib import Path

import numpy as np
import shapely
from PIL import Image, ImageDraw
from shapely import affinity
from svgpathtools import parse_path

from tactical_alignment_receiver import flatten


MAPS = (
    "abyss", "ascent", "bind", "breeze", "corrode", "fracture", "haven",
    "icebox", "lotus", "pearl", "split", "summit", "sunset",
)
WALL = "#b27c40"
RECEIVER = "#271406"
ERROR = 0.0001
NUMBER = r"[-+]?(?:\d*\.\d+|\d+\.?)(?:[eE][-+]?\d+)?"
STYLE_KEYS = (
    "fill", "stroke", "stroke-width", "stroke-linecap", "stroke-linejoin",
    "stroke-miterlimit", "stroke-dasharray", "stroke-dashoffset", "fill-rule",
    "display", "visibility", "opacity", "fill-opacity", "stroke-opacity",
    "vector-effect", "mask", "clip-path",
)


def sha256(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def write_json(path, value):
    path.write_text(json.dumps(value, separators=(",", ":"), allow_nan=False) + "\n")


def tag(element):
    return element.tag.split("}")[-1]


def style_for(element, inherited):
    result = dict(inherited)
    for declaration in element.get("style", "").split(";"):
        if ":" in declaration:
            name, value = declaration.split(":", 1)
            result[name.strip()] = value.strip()
    for name in STYLE_KEYS:
        if element.get(name) is not None:
            result[name] = element.get(name)
    return result


def matrix_for(text):
    matrix = np.eye(3)
    if not text:
        return matrix
    cursor = 0
    for match in re.finditer(r"([A-Za-z]+)\s*\(([^)]*)\)", text):
        if text[cursor:match.start()].strip(" ,\t\r\n"):
            raise ValueError(f"unsupported transform syntax: {text}")
        cursor = match.end()
        name = match.group(1)
        values = [float(value) for value in re.findall(NUMBER, match.group(2))]
        operation = np.eye(3)
        if name == "matrix" and len(values) == 6:
            a, b, c, d, e, f = values
            operation = np.array([[a, c, e], [b, d, f], [0, 0, 1]], float)
        elif name == "translate" and len(values) in (1, 2):
            operation[0, 2] = values[0]
            operation[1, 2] = values[1] if len(values) == 2 else 0
        elif name == "scale" and len(values) in (1, 2):
            operation[0, 0] = values[0]
            operation[1, 1] = values[1] if len(values) == 2 else values[0]
        elif name == "rotate" and len(values) in (1, 3):
            angle = math.radians(values[0])
            rotation = np.array([[math.cos(angle), -math.sin(angle), 0],
                                 [math.sin(angle), math.cos(angle), 0],
                                 [0, 0, 1]])
            if len(values) == 3:
                x, y = values[1:]
                before = np.array([[1, 0, x], [0, 1, y], [0, 0, 1]], float)
                after = np.array([[1, 0, -x], [0, 1, -y], [0, 0, 1]], float)
                operation = before @ rotation @ after
            else:
                operation = rotation
        elif name in ("skewX", "skewY") and len(values) == 1:
            operation[0 if name == "skewX" else 1,
                      1 if name == "skewX" else 0] = math.tan(math.radians(values[0]))
        else:
            raise ValueError(f"unsupported transform: {match.group(0)}")
        matrix = matrix @ operation
    if text[cursor:].strip(" ,\t\r\n"):
        raise ValueError(f"unsupported transform syntax: {text}")
    return matrix


def transformed(geometry, matrix):
    return affinity.affine_transform(
        geometry,
        [matrix[0, 0], matrix[0, 1], matrix[1, 0], matrix[1, 1],
         matrix[0, 2], matrix[1, 2]],
    )


def circle_points(cx, cy, rx, ry):
    radius = max(rx, ry)
    count = max(32, math.ceil(math.pi / math.acos(1 - min(ERROR / radius, .999))))
    return np.array([[cx + rx * math.cos(t), cy + ry * math.sin(t)]
                     for t in np.linspace(0, 2 * math.pi, count + 1)])


def rounded_rect_points(element):
    x = float(element.get("x", 0)); y = float(element.get("y", 0))
    width = float(element.get("width")); height = float(element.get("height"))
    rx_value, ry_value = element.get("rx"), element.get("ry")
    if rx_value is None and ry_value is None:
        return np.array([[x, y], [x + width, y], [x + width, y + height],
                         [x, y + height], [x, y]])
    rx = min(float(rx_value or ry_value), width / 2)
    ry = min(float(ry_value or rx_value), height / 2)
    radius = max(rx, ry)
    quarter = max(8, math.ceil((math.pi / 2) /
                               math.acos(1 - min(ERROR / radius, .999))))
    result = []
    for cx, cy, start in ((x + width - rx, y + ry, -math.pi / 2),
                          (x + width - rx, y + height - ry, 0),
                          (x + rx, y + height - ry, math.pi / 2),
                          (x + rx, y + ry, math.pi)):
        result.extend((cx + rx * math.cos(t), cy + ry * math.sin(t))
                      for t in np.linspace(start, start + math.pi / 2, quarter + 1)[:-1])
    result.append(result[0])
    return np.array(result)


def contours(element):
    kind = tag(element)
    if kind == "path":
        result = []
        for subpath in parse_path(element.get("d", "")).continuous_subpaths():
            points = []
            for segment in subpath:
                points.extend(flatten(segment, ERROR)[:-1])
            if not subpath:
                continue
            points.append(subpath[-1].end)
            result.append((np.array([[p.real, p.imag] for p in points]), subpath.isclosed()))
        return result
    if kind in ("circle", "ellipse"):
        rx = float(element.get("r")) if kind == "circle" else float(element.get("rx"))
        ry = float(element.get("r")) if kind == "circle" else float(element.get("ry"))
        return [(circle_points(float(element.get("cx", 0)), float(element.get("cy", 0)),
                               rx, ry), True)]
    if kind == "rect":
        return [(rounded_rect_points(element), True)]
    if kind in ("polyline", "polygon"):
        values = [float(value) for value in re.findall(NUMBER, element.get("points", ""))]
        if len(values) < 4 or len(values) % 2:
            raise ValueError("invalid points")
        points = np.array(values).reshape(-1, 2)
        closed = kind == "polygon"
        if closed and not np.array_equal(points[0], points[-1]):
            points = np.vstack((points, points[0]))
        return [(points, closed)]
    if kind == "line":
        return [(np.array([[float(element.get("x1", 0)), float(element.get("y1", 0))],
                           [float(element.get("x2", 0)), float(element.get("y2", 0))]]), False)]
    raise ValueError(f"unsupported painted element {kind}")


def filled(element, fill_rule):
    paths = []
    for points, _ in contours(element):
        if len(points) < 2:
            continue
        if not np.array_equal(points[0], points[-1]):
            points = np.vstack((points, points[0]))
        paths.append(points)
    if not paths:
        return shapely.GeometryCollection()
    lines = shapely.union_all([shapely.LineString(points) for points in paths])
    polygons = list(shapely.polygonize(shapely.get_parts(lines)).geoms)
    starts = np.concatenate([points[:-1] for points in paths])
    ends = np.concatenate([points[1:] for points in paths])
    accepted = []
    for polygon in polygons:
        point = np.array(polygon.representative_point().coords)[0]
        cross = ((ends[:, 0] - starts[:, 0]) * (point[1] - starts[:, 1]) -
                 (ends[:, 1] - starts[:, 1]) * (point[0] - starts[:, 0]))
        winding = int(((starts[:, 1] <= point[1]) & (ends[:, 1] > point[1]) &
                       (cross > 0)).sum() -
                      ((starts[:, 1] > point[1]) & (ends[:, 1] <= point[1]) &
                       (cross < 0)).sum())
        if (abs(winding) % 2 == 1) if fill_rule == "evenodd" else winding != 0:
            accepted.append(polygon)
    return shapely.union_all(accepted)


def dash_lines(points, pattern, offset):
    if len(points) < 2:
        return []
    if len(pattern) % 2:
        pattern *= 2
    period = sum(pattern)
    if period <= 0 or any(value < 0 for value in pattern):
        raise ValueError("invalid stroke dash pattern")
    phase = (-offset) % period
    pattern_index = 0
    while phase >= pattern[pattern_index] and pattern[pattern_index] > 0:
        phase -= pattern[pattern_index]
        pattern_index = (pattern_index + 1) % len(pattern)
    remaining = pattern[pattern_index] - phase
    on = pattern_index % 2 == 0
    output = []
    for first, last in zip(points[:-1], points[1:]):
        delta = last - first
        length = float(np.linalg.norm(delta))
        if length == 0:
            continue
        used = 0.0
        while used < length:
            take = min(remaining, length - used)
            if on and take > 0:
                output.append(np.array([first + delta * (used / length),
                                        first + delta * ((used + take) / length)]))
            used += take
            remaining -= take
            if remaining <= 1e-12:
                pattern_index = (pattern_index + 1) % len(pattern)
                remaining = pattern[pattern_index]
                on = pattern_index % 2 == 0
    return output


def stroked(element, style):
    width = float(style.get("stroke-width", 1))
    if width <= 0:
        return shapely.GeometryCollection()
    dash_text = style.get("stroke-dasharray", "none")
    pattern = [] if dash_text == "none" else [float(value) for value in re.findall(NUMBER, dash_text)]
    lines = []
    for points, _ in contours(element):
        lines.extend(dash_lines(points, pattern, float(style.get("stroke-dashoffset", 0)))
                     if pattern else [points])
    cap = style.get("stroke-linecap", "butt")
    join = style.get("stroke-linejoin", "miter")
    if cap not in ("butt", "round", "square") or join not in ("miter", "round", "bevel"):
        raise ValueError("unsupported stroke cap or join")
    radius = width / 2
    quad_segs = max(8, math.ceil(math.pi /
                                 (4 * math.acos(1 - min(ERROR / radius, .999)))))
    return shapely.union_all([
        shapely.LineString(points).buffer(
            radius, cap_style={"round": 1, "butt": 2, "square": 3}[cap],
            join_style={"round": 1, "miter": 2, "bevel": 3}[join],
            mitre_limit=float(style.get("stroke-miterlimit", 4)), quad_segs=quad_segs)
        for points in lines if len(points) >= 2
    ])


def polygon_parts(geometry):
    return sorted((part for part in shapely.get_parts(geometry)
                   if isinstance(part, shapely.Polygon) and part.area > 0),
                  key=lambda part: part.bounds)


def rings(polygon):
    return [[coordinate for point in ring.coords for coordinate in point]
            for ring in (polygon.exterior, *polygon.interiors)]


def from_rings(value):
    arrays = [np.array(ring).reshape(-1, 2) for ring in value]
    return shapely.Polygon(arrays[0], arrays[1:])


def resolve_mask(root, mask_reference, parent_matrix):
    match = re.fullmatch(r"url\(#([^)]+)\)", mask_reference)
    if not match:
        raise ValueError(f"unsupported mask reference {mask_reference}")
    mask = next((element for element in root.iter()
                 if element.get("id") == match.group(1)), None)
    if mask is None or tag(mask) != "mask" or mask.get("maskUnits", "objectBoundingBox") != "userSpaceOnUse":
        raise ValueError("unsupported or missing mask")
    white = shapely.GeometryCollection(); black = shapely.GeometryCollection()
    inherited = style_for(mask, {})
    for child in mask:
        style = style_for(child, inherited)
        if tag(child) not in ("path", "rect", "circle", "ellipse", "polygon"):
            raise ValueError("unsupported mask child")
        geometry = transformed(filled(child, style.get("fill-rule", "nonzero")),
                               parent_matrix @ matrix_for(child.get("transform")))
        color = style.get("fill", "black").lower()
        if color in ("white", "#fff", "#ffffff"):
            white = shapely.union_all([white, geometry])
        elif color in ("black", "#000", "#000000"):
            black = shapely.union_all([black, geometry])
        else:
            raise ValueError(f"unsupported mask color {color}")
    return shapely.difference(white, black)


def extract_map(map_name, side, source):
    root = ET.parse(source).getroot()
    view_box = [float(value) for value in root.get("viewBox").split()]
    if len(view_box) != 4 or view_box[2] <= 0 or view_box[3] <= 0:
        raise ValueError(f"invalid viewBox in {source}")
    walls, receivers, unsupported = [], [], []
    source_walls, source_receivers = [], []

    def visit(element, inherited_style, parent_matrix, element_path, root_index):
        kind = tag(element)
        if kind in ("mask", "defs", "clipPath"):
            return
        style = style_for(element, inherited_style)
        matrix = parent_matrix @ matrix_for(element.get("transform"))
        if style.get("display") == "none" or style.get("visibility") == "hidden":
            return
        fill = style.get("fill", "black").lower()
        stroke = style.get("stroke", "none").lower()
        channels = []
        if fill == WALL:
            channels.append(("fill", WALL))
        if stroke == WALL:
            channels.append(("stroke", WALL))
        if fill == RECEIVER:
            channels.append(("fill", RECEIVER))
        for channel, color in channels:
            try:
                if style.get("vector-effect", "none") != "none" or style.get("clip-path"):
                    raise ValueError("vector-effect or clip-path requires implementation")
                local = (filled(element, style.get("fill-rule", "nonzero"))
                         if channel == "fill" else stroked(element, style))
                geometry = transformed(local, matrix)
                mask_reference = style.get("mask")
                if mask_reference:
                    geometry = shapely.intersection(
                        geometry, resolve_mask(root, mask_reference, parent_matrix))
                source = dict(
                    paintChannel=channel,
                    resolvedStyle={name: style[name] for name in STYLE_KEYS if name in style},
                    transform=element.get("transform"),
                    mask=mask_reference,
                    attributes=dict(element.attrib),
                )
                target = receivers if color == RECEIVER else walls
                source_target = source_receivers if color == RECEIVER else source_walls
                source_target.append(geometry)
                for component, polygon in enumerate(polygon_parts(geometry)):
                    target.append(dict(
                        id=f"p{root_index}-{channel}-{component}",
                        sourcePathIndex=root_index,
                        sourceElementPath=element_path,
                        element=kind,
                        rings=rings(polygon),
                        fillRule="evenodd",
                        source=source,
                    ))
            except Exception as error:
                unsupported.append(dict(sourcePathIndex=root_index,
                                        sourceElementPath=element_path,
                                        element=kind, reason=str(error),
                                        attributes=dict(element.attrib)))
        for child_index, child in enumerate(element):
            visit(child, style, matrix, [*element_path, child_index], root_index)

    root_style = style_for(root, {})
    root_matrix = matrix_for(root.get("transform"))
    for root_index, element in enumerate(root):
        visit(element, root_style, root_matrix, [root_index], root_index)

    source_wall = shapely.union_all(source_walls)
    source_receiver = shapely.union_all(source_receivers)
    exported_wall = shapely.union_all([from_rings(row["rings"]) for row in walls])
    exported_receiver = shapely.union_all([from_rings(row["rings"]) for row in receivers])
    wall_difference = shapely.symmetric_difference(source_wall, exported_wall).area
    receiver_difference = shapely.symmetric_difference(source_receiver, exported_receiver).area
    if wall_difference > 1e-7 or receiver_difference > 1e-7:
        raise AssertionError(f"ring round-trip changed painted ink in {source}")
    model = dict(
        version=1, map=map_name, side=side, coordinateSpace="svg", viewBox=view_box,
        sourceSvg=dict(path=str(source), sha256=sha256(source)),
        curveFlatteningErrorSvg=ERROR, strokeArcErrorSvg=ERROR,
        walls=walls, receivers=receivers, unsupported=unsupported,
        validation=dict(
            sourceWallAreaSvg2=source_wall.area,
            serializedWallAreaSvg2=exported_wall.area,
            wallSymmetricDifferenceSvg2=wall_difference,
            sourceReceiverAreaSvg2=source_receiver.area,
            serializedReceiverAreaSvg2=exported_receiver.area,
            receiverSymmetricDifferenceSvg2=receiver_difference,
        ),
    )
    return model, source_wall, source_receiver


def draw_geometry(image, geometry, view_box, origin_x, width, color):
    draw = ImageDraw.Draw(image, "RGBA")
    x, y, w, h = view_box
    scale = min((width - 20) / w, (image.height - 40) / h)
    offset_x = origin_x + (width - w * scale) / 2
    offset_y = 25 + (image.height - 40 - h * scale) / 2
    def coordinates(ring):
        return [(offset_x + (px - x) * scale, offset_y + (py - y) * scale)
                for px, py in ring.coords]
    for polygon in polygon_parts(geometry):
        draw.polygon(coordinates(polygon.exterior), fill=color)
        for interior in polygon.interiors:
            draw.polygon(coordinates(interior), fill=(247, 244, 238, 255))


def review_render(path, map_name, pairs):
    image = Image.new("RGB", (1100, 620), (247, 244, 238))
    draw = ImageDraw.Draw(image)
    draw.text((15, 6), f"{map_name} attack", fill=(30, 25, 20))
    draw.text((565, 6), f"{map_name} defense", fill=(30, 25, 20))
    for column, (_, walls, receivers, view_box) in enumerate(pairs):
        draw_geometry(image, receivers, view_box, column * 550, 550, (39, 20, 6, 255))
        draw_geometry(image, walls, view_box, column * 550, 550, (178, 124, 64, 255))
    image.save(path)
    return image.resize((275, 155), Image.Resampling.LANCZOS)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=Path, default=Path(
        "E:/IcarusWorldAudit/2026-09-06/tactical-visibility-revision/all-map-svg-footprints-v1"))
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    review_dir = args.output / "review"
    review_dir.mkdir(exist_ok=True)
    reports, thumbnails = [], []
    for map_name in MAPS:
        pairs = []
        for side, suffix in (("attack", "_map.svg"),
                             ("defense", "_map_defense.svg")):
            source = Path("assets/maps") / f"{map_name}{suffix}"
            model, walls, receivers = extract_map(map_name, side, source)
            output = args.output / f"{map_name}-{side}.json"
            write_json(output, model)
            reports.append(dict(
                map=map_name, side=side, file=str(output), sha256=sha256(output),
                bytes=output.stat().st_size, wallComponents=len(model["walls"]),
                receiverComponents=len(model["receivers"]),
                unsupported=len(model["unsupported"]), validation=model["validation"],
            ))
            pairs.append((side, walls, receivers, model["viewBox"]))
        render_path = review_dir / f"{map_name}.png"
        thumbnails.append(review_render(render_path, map_name, pairs))
    atlas = Image.new("RGB", (1100, math.ceil(len(thumbnails) / 4) * 155),
                      (247, 244, 238))
    for index, image in enumerate(thumbnails):
        atlas.paste(image, ((index % 4) * 275, (index // 4) * 155))
    atlas.save(review_dir / "all-maps.png")
    report = dict(
        schema="literal-svg-painted-footprints-v1", maps=list(MAPS), sides=2,
        sourceColorPolicy=dict(wall=WALL, receiver=RECEIVER),
        curveFlatteningErrorSvg=ERROR, strokeArcErrorSvg=ERROR,
        outputs=reports, unsupportedTotal=sum(row["unsupported"] for row in reports),
        reviewAtlas=str(review_dir / "all-maps.png"),
        limitations=[
            "This artifact contains XY paint only. It makes no wall-height, support, opening, or gameplay claims.",
            "Curves and round stroke features are flattened within the recorded SVG-space error.",
            "A zero unsupported count means the extractor handled the SVG constructs present in these files; it is not gameplay validation.",
        ],
        builder=dict(path=str(Path(__file__)), sha256=sha256(Path(__file__))),
        productionMutation=False,
    )
    write_json(args.output / "report.json", report)
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()

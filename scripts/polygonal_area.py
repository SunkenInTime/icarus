"""Extract polygonal members without rebuilding or buffering their boundaries."""
import shapely


def polygonal(shape):
    if shape.geom_type in ('Polygon', 'MultiPolygon'):
        return shape
    polygons = []

    def collect(geometry):
        if geometry.geom_type == 'Polygon':
            polygons.append(geometry)
        elif geometry.geom_type in ('MultiPolygon', 'GeometryCollection'):
            for part in shapely.get_parts(geometry):
                collect(part)

    collect(shape)
    return shapely.MultiPolygon(polygons) if polygons else shapely.Polygon()

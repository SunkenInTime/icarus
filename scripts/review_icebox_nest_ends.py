"""Measure both drawn ends of each gameplay-confirmed Nest assembly.

The assembly is selected once. Its opposite SVG ends are discovered together,
including an end embedded in a longer painted path. Only height intervals are
replaced; the original painted footprint and all unrelated height data remain.
"""
import argparse
import gzip
import hashlib
import json
from pathlib import Path

import numpy as np
import shapely
from shapely.affinity import affine_transform

from audit_all_map_gameplay_levels import OUT, ROOT, read
from compile_reviewed_svg_height_map import polygon, rings
from review_icebox_gameplay_openings import vertical_intervals
from svg_review_source import source_world


ASSEMBLIES = [
    dict(id='defender-nest', floor=3749, base=3747,
         objects=[3747, 3748, 3749, 3750],
         evidence='Saved gameplay review 1788837450544-1eab447c, cone 4; '
                  'existing eligible defender Nest interior floor.'),
    dict(id='attacker-nest', floor=3745, base=3743,
         objects=[3743, 3744, 3745, 3746],
         evidence='Previously reviewed attacker Nest interior and open end; '
                  'existing eligible attacker Nest interior floor.'),
]


def find_drawn_ends(walls, source_bounds, tolerance=3.0):
    """Find both end strips of a long rectangular floor without wall-id lists."""
    source_bounds = np.asarray(source_bounds).reshape(2, 2)
    long_axis = int(np.argmax(source_bounds[1] - source_bounds[0]))
    along_axis = 1 - long_axis
    short_low, short_high = source_bounds[:, along_axis]
    short_length = short_high - short_low
    found = []
    for end in range(2):
        candidates = []
        for wall in walls:
            for raw in wall['rings']:
                points = np.asarray(raw).reshape(-1, 2)
                for a, b in zip(points, np.roll(points, -1, axis=0)):
                    if abs(a[long_axis] - b[long_axis]) > 1e-7:
                        continue
                    low, high = sorted([a[along_axis], b[along_axis]])
                    overlap = max(0., min(high, short_high) - max(low, short_low))
                    distance = abs(a[long_axis] - source_bounds[end, long_axis])
                    if overlap < short_length * .6 or distance > tolerance:
                        continue
                    candidates.append((distance, high - low, wall['id'],
                                       float(a[long_axis]), low, high))
        if not candidates:
            raise ValueError(('Missing drawn Nest end', end, source_bounds.tolist()))
        best = min(candidates)
        same_strip = [r for r in candidates if r[2] == best[2]
                      and abs(r[3] - best[3]) < 1.6]
        found.append(dict(wallId=best[2], axis=long_axis,
                          cross=[min(r[3] for r in same_strip),
                                 max(r[3] for r in same_strip)],
                          along=[best[4], best[5]]))
    if found[0]['wallId'] == found[1]['wallId'] and found[0]['cross'] == found[1]['cross']:
        raise ValueError('One painted strip cannot stand in for both Nest ends')
    # One end can belong to a path that continues below the room. The shorter
    # opposite edge establishes the authored room span, not the source XY.
    span = min((r['along'] for r in found), key=lambda r: r[1] - r[0])
    for row in found:
        if row['along'][1] - row['along'][0] > (span[1] - span[0]) * 1.3:
            row['along'] = list(span)
    return found


def closed_bands(measured, seam_tolerance=.08):
    """Close tiny construction seams while retaining meaningful openings."""
    merged = []
    for low, high in measured:
        if merged and low <= merged[-1][1] + seam_tolerance:
            merged[-1][1] = max(merged[-1][1], high)
        else:
            merged.append([float(low), float(high)])
    if not merged:
        raise ValueError('No source bands for a drawn Nest section')
    merged[0][0] = min(0., merged[0][0])
    return merged


def clip_box(axis, cross, along):
    return ([cross[0], along[0], cross[1], along[1]] if axis == 0
            else [along[0], cross[0], along[1], cross[1]])


def replace_sections(model, profiles, transform=None):
    walls = model['walls']
    before_ink = shapely.union_all([polygon(w) for w in walls])
    for profile in profiles:
        parent = profile['wallId']
        region = shapely.box(*profile['clipBox'])
        if transform is not None:
            region = affine_transform(region, transform)
            # The paired artwork differs by up to .0011 SVG units. Cover its
            # literal stroke through that measured registration discrepancy.
            # This expands only the height-association mask, never runtime ink.
            region = region.buffer(.002, join_style='mitre')
            # Paired artwork has different path identifiers. The transformed
            # painted end identifies its mate; matching IDs selects other ink.
            family = [w for w in walls if polygon(w).intersection(region).area > 1e-10]
        else:
            family = [w for w in walls if w['id'] == parent or w['id'].startswith(parent + '-')]
        if not family:
            raise ValueError(('Missing painted wall family', parent))
        emitted = []
        measured_area = 0.
        for original in family:
            remaining = polygon(original)
            for section in profile['sections']:
                clip = shapely.box(*section['clipBox'])
                if transform is not None:
                    clip = affine_transform(clip, transform)
                    x0, y0, x1, y1 = clip.bounds
                    if x1 - x0 > y1 - y0:
                        clip = shapely.box(x0 - .002, y0, x1 + .002, y1)
                    else:
                        clip = shapely.box(x0, y0 - .002, x1, y1 + .002)
                cut = remaining.intersection(region).intersection(clip)
                for index, part in enumerate(shapely.get_parts(cut)):
                    if part.geom_type != 'Polygon' or part.area < 1e-12:
                        continue
                    emitted.append(dict(original,
                        id=f'{original["id"]}-paired-nest-profile-{section["index"]}-{index}',
                        rings=rings(part), fillRule='evenodd',
                        floorElevationMeters=0., bands=section['bands'],
                        unknownHeight=False))
                    measured_area += part.area
                remaining = remaining.difference(cut)
            for index, part in enumerate(shapely.get_parts(remaining)):
                if part.geom_type == 'Polygon' and part.area >= 1e-12:
                    emitted.append(dict(original,
                        id=f'{original["id"]}-paired-nest-profile-remainder-{index}',
                        rings=rings(part), fillRule='evenodd'))
        original_ink = shapely.union_all([polygon(w) for w in family])
        if measured_area < .1:
            raise ValueError(('No meaningful Nest end was partitioned', parent))
        new_ink = shapely.union_all([polygon(w) for w in emitted])
        if original_ink.symmetric_difference(new_ink).area >= 1e-7:
            raise ValueError(('Nest partition changed painted ink', parent))
        ids = {w['id'] for w in family}
        walls = [w for w in walls if w['id'] not in ids] + emitted
    if before_ink.symmetric_difference(shapely.union_all([polygon(w) for w in walls])).area >= 1e-7:
        raise ValueError('Nest profiles changed the complete painted footprint')
    return {**model, 'walls': walls}


def measure():
    source_path = source_world('icebox') / 'geometry.npz'
    metadata = read(source_path.with_suffix('.json'))
    objects = metadata['objects']
    archive = np.load(source_path)
    alignment_path = ROOT / 'tactical-alignment-sides-v1/icebox.json'
    alignment = read(alignment_path)
    attack = np.asarray(alignment['nativeToAttackSvg'])
    defense = np.asarray(alignment['nativeToDefenseSvg'])
    linear = defense[:, :2] @ np.linalg.inv(attack[:, :2])
    shift = defense[:, 2] - linear @ attack[:, 2]
    transform = [*linear[0], *linear[1], *shift]
    artwork_path = OUT.parent / 'all-map-svg-footprints-v1/icebox-attack.json'
    artwork = read(artwork_path)

    def triangles(ids):
        tri = np.concatenate([
            archive['points'][archive['faces'][objects[i]['firstFace']:
                objects[i]['firstFace'] + objects[i]['faceCount']]] for i in ids
        ]).astype(float)
        tri[:, :, :2] = tri[:, :, :2] @ attack[:, :2].T + attack[:, 2]
        return tri

    profiles = []
    for assembly in ASSEMBLIES:
        floor = triangles([assembly['floor']])
        base = triangles([assembly['base']])
        source = triangles(assembly['objects'])
        floor_bounds = np.array([floor[:, :, :2].min((0, 1)),
                                 floor[:, :, :2].max((0, 1))])
        ends = find_drawn_ends(artwork['walls'], floor_bounds)
        for end, wall in enumerate(ends):
            axis = wall['axis']
            cross = [floor_bounds[end, axis] - .75, floor_bounds[end, axis] + .75]
            source_along = [float(base[:, :, 1 - axis].min()),
                            float(base[:, :, 1 - axis].max())]
            target_along = wall['along']
            # Include stroke caps at the seam with the adjacent painted side.
            target_cross = [wall['cross'][0] - 1e-7, wall['cross'][1] + 1e-7]
            edges = np.linspace(0, 1, int(np.ceil((target_along[1] - target_along[0]) / .4)) + 1)
            sections = []
            for index, (start, stop) in enumerate(zip(edges, edges[1:])):
                section = [source_along[0] + f * (source_along[1] - source_along[0])
                           for f in [start, stop]]
                drawn = [target_along[0] + f * (target_along[1] - target_along[0])
                         for f in [start, stop]]
                measured = vertical_intervals(source, axis, cross, section)
                sections.append(dict(index=index, sourceAlong=section,
                    clipBox=clip_box(axis, target_cross, drawn),
                    bands=closed_bands(measured)))
            profiles.append(dict(assembly=assembly['id'], end=end,
                wallId=wall['wallId'], clipBox=clip_box(axis, target_cross, target_along),
                sourceCross=cross, sourceAlong=source_along,
                sourceObjects=assembly['objects'],
                sourcePaths=[objects[i]['path'] for i in assembly['objects']],
                gameplayEvidence=assembly['evidence'], sections=sections))
    evidence = dict(schemaVersion=1, map='icebox', profiles=profiles,
        sourceGeometrySha256=hashlib.sha256(source_path.read_bytes()).hexdigest(),
        alignmentSha256=hashlib.sha256(alignment_path.read_bytes()).hexdigest(),
        artworkFootprintsSha256=hashlib.sha256(artwork_path.read_bytes()).hexdigest(),
        policy='Discover and measure both painted ends of each confirmed Nest '
               'assembly. Preserve solid bases, sides, and overhead structure. '
               'Source cross-sections supply heights, never replacement wall XY.')
    return evidence, transform


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--directory', type=Path, default=OUT / 'icebox')
    parser.add_argument('--update-candidates', action='store_true')
    args = parser.parse_args()
    evidence, transform = measure()
    writes = []
    for side in ['attack', 'defense']:
        prefixes = ['height-base'] + (['candidate'] if args.update_candidates else [])
        for prefix in prefixes:
            path = args.directory / f'{prefix}-{side}.json.gz'
            model = read(path)
            # Re-running this stage must not repeatedly partition its own output.
            if any('-paired-nest-profile-' in w['id'] for w in model['walls']):
                raise ValueError(f'Nest end profiles already installed in {path}')
            updated = replace_sections(model, evidence['profiles'],
                                       transform if side == 'defense' else None)
            writes.append((path, gzip.compress(json.dumps(updated,
                separators=(',', ':'), allow_nan=False).encode(), mtime=0)))
    for path, payload in writes:
        path.write_bytes(payload)
    (args.directory / 'nest-end-review.json').write_text(json.dumps(evidence, indent=2))
    print(json.dumps(dict(profiles=len(evidence['profiles']),
        sections=sum(len(p['sections']) for p in evidence['profiles']),
        walls=[p['wallId'] for p in evidence['profiles']], files=len(writes))))


if __name__ == '__main__':
    main()

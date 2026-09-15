"""Inventory adjacent low wall caps for source review. Never changes map assets.

Numeric cap jumps are review candidates, not evidence of a gameplay opening or
an incorrect wall. Source identities come from nearby archived profile stations
and may predate subsequent reviewed corrections.
"""
import argparse
from collections import Counter, defaultdict
import gzip
import hashlib
import json
from pathlib import Path
import re

import numpy as np
import shapely
from shapely.affinity import affine_transform

from compile_reviewed_svg_height_map import polygon

ROOT = Path('E:/IcarusWorldAudit/2026-09-06')


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def read(path):
    raw = path.read_bytes()
    return json.loads(gzip.decompress(raw) if path.suffix == '.gz' else raw)


def parent(wall):
    match = re.match(r'p\d+-(?:stroke|fill)-\d+', wall['id'])
    return match.group() if match else wall['id']


def cap(wall):
    bands = wall.get('bands', [])
    if wall.get('unknownHeight') or len(bands) != 1 or bands[0][1] is None:
        return None
    value = wall.get('floorElevationMeters', 0.) + bands[0][1]
    return float(value) if np.isfinite(value) else None


def source_class(source):
    roles = {source.get('sourceRole'), *[c.get('role') for c in (source.get('sourceComponents') or [])]}
    if 'structure' in roles:
        return 'structural-assembly-review'
    if roles & {'box', 'cover', 'prop', 'low-cover'}:
        return 'box-or-prop-review'
    if roles & {'floor', 'ground', 'ramp', 'stairs', 'support'}:
        return 'floor-or-ramp-review'
    return 'other-or-unmatched-source-review'


def audit(name, args):
    profile_path = args.profile_root / name / 'local-source-profiles.json'
    alignment_path = args.alignment_root / (name + '.json')
    profile, alignment = read(profile_path), read(alignment_path)
    stations = defaultdict(list)
    for record_index, record in enumerate(profile['records']):
        for station_index, station in enumerate(record['stations']):
            stations[record['wallId']].append((record_index, station_index, station))
    profile_hash, alignment_hash = sha(profile_path), sha(alignment_path)
    station_trees = {key: shapely.STRtree([shapely.Point(s[2]['svg']) for s in rows])
                     for key, rows in stations.items() if rows}
    all_stations = [(pid, *s) for pid, rows in stations.items() for s in rows]
    all_station_tree = shapely.STRtree([shapely.Point(s[3]['svg']) for s in all_stations])
    attack, defense = [np.asarray(alignment[f'nativeTo{s}Svg']) for s in ['Attack', 'Defense']]
    linear = attack[:, :2] @ np.linalg.inv(defense[:, :2])
    shift = attack[:, 2] - linear @ defense[:, 2]
    transform = [*linear[0], *linear[1], *shift]
    candidates, inventories, asset_hashes = [], {}, {}
    for side in ['attack', 'defense']:
        asset_path = args.assets / f'{name}_svg_height_{side}.json.gz'
        asset_hashes[side] = sha(asset_path)
        model = read(asset_path)
        groups = defaultdict(list)
        counts = Counter(walls=len(model['walls']))
        for wall in model['walls']:
            groups[parent(wall)].append(wall)
        counts['authoredParents'] = len(groups)
        for pid, walls in sorted(groups.items()):
            shapes = [polygon(w) for w in walls]
            tops = [cap(w) for w in walls]
            counts['finiteSingleBandWalls'] += sum(t is not None for t in tops)
            counts['otherBandWalls'] += sum(t is None for t in tops)
            counts['emptyFootprints'] += sum(s.is_empty or s.area == 0 for s in shapes)
            tree = shapely.STRtree(shapes)
            edges = defaultdict(set)
            high = defaultdict(set)
            for i, shape in enumerate(shapes):
                if tops[i] is None or shape.is_empty or shape.area == 0:
                    continue
                for j in tree.query(shape.buffer(args.adjacency_svg), predicate='intersects'):
                    j = int(j)
                    if j <= i or tops[j] is None or shapes[j].area == 0:
                        continue
                    counts['finiteAdjacencyPairs'] += 1
                    difference = tops[j] - tops[i]
                    if abs(difference) <= args.cap_tolerance:
                        edges[i].add(j)
                        edges[j].add(i)
                    elif abs(difference) > args.camera_height:
                        lo, hi = (i, j) if difference > 0 else (j, i)
                        high[lo].add(hi)
                        counts['capDropPairs'] += 1
            visited = set()
            for seed in sorted(high):
                if seed in visited:
                    continue
                pending, island = [seed], set()
                while pending:
                    i = pending.pop()
                    if i in island:
                        continue
                    island.add(i)
                    pending.extend(edges[i] - island)
                visited.update(island)
                neighbors = set().union(*(high[i] for i in island)) - island
                if not neighbors:
                    continue

                def row(i):
                    wall, shape = walls[i], shapes[i]
                    point = shape.representative_point()
                    query = affine_transform(point, transform) if side == 'defense' else point
                    nearest = None
                    if all_stations:
                        if side == 'attack' and pid in station_trees:
                            k = int(station_trees[pid].nearest(query))
                            ri, si, source = stations[pid][k]
                            source_parent = pid
                        else:
                            k = int(all_station_tree.nearest(query))
                            source_parent, ri, si, source = all_stations[k]
                        nearest = {key: source.get(key) for key in [
                            'svg', 'associationSvg', 'sourceObject', 'sourcePath', 'sourceRole',
                            'sourceComponents', 'sourceBands', 'measuredTopMeters',
                            'measuredBottomMeters', 'floorElevationMeters', 'status']}
                        nearest.update(profileRecordIndex=ri, stationIndex=si,
                                       sourceParent=source_parent,
                                       distanceSvg=float(query.distance(shapely.Point(source['svg']))))
                    return dict(wallId=wall['id'], bands=wall['bands'],
                                floorElevationMeters=wall.get('floorElevationMeters', 0.),
                                absoluteCapMeters=tops[i], areaSvg=float(shape.area),
                                boundsSvg=list(shape.bounds), representativeSvg=[point.x, point.y],
                                nearestSource=nearest)

                low_rows = [row(i) for i in sorted(island)]
                high_rows = [row(i) for i in sorted(neighbors)]
                kinds = sorted({source_class(r['nearestSource'] or {}) for r in low_rows})
                span = shapely.union_all([shapes[i] for i in island])
                jumps = [tops[j] - tops[i] for i in island for j in high[i] if j in neighbors]
                plinth_pairs = []
                for low in low_rows:
                    source = low['nearestSource'] or {}
                    floor = source.get('floorElevationMeters')
                    if floor is None or source.get('distanceSvg', float('inf')) > 2.:
                        continue
                    above_floor = low['absoluteCapMeters'] - floor
                    if not 0 <= above_floor <= args.camera_height:
                        continue
                    if source.get('measuredTopMeters') is None or abs(source['measuredTopMeters'] - low['absoluteCapMeters']) > .1:
                        continue
                    for tall in high_rows:
                        other = tall['nearestSource'] or {}
                        if (source.get('sourceObject') is not None
                            and source.get('sourceObject') == other.get('sourceObject')
                            and other.get('distanceSvg', float('inf')) <= 2.
                            and source_class(source) == 'structural-assembly-review'
                            and tall['absoluteCapMeters'] - low['absoluteCapMeters'] > 2 * args.camera_height):
                            plinth_pairs.append(dict(lowWallId=low['wallId'], highWallId=tall['wallId'],
                                sourceObject=source['sourceObject'], sourcePath=source.get('sourcePath'),
                                lowCapMeters=low['absoluteCapMeters'], highCapMeters=tall['absoluteCapMeters'],
                                capAboveArchivedGroundMeters=above_floor))
                candidates.append(dict(map=name, side=side, parent=pid,
                    sameSourcePlinthPairs=plinth_pairs,
                    classification=kinds, lowCellCount=len(island), highNeighborCount=len(neighbors),
                    persistentMultipleCells=len(island) >= 2,
                    lowCapRangeMeters=[min(tops[i] for i in island), max(tops[i] for i in island)],
                    highCapRangeMeters=[min(tops[i] for i in neighbors), max(tops[i] for i in neighbors)],
                    maximumAdjacentJumpMeters=max(jumps), areaSvg=float(span.area),
                    boundsSvg=list(span.bounds), lowWalls=low_rows, adjacentHighWalls=high_rows,
                    verdict='source-review-required'))
        counts['candidateIslands'] = sum(c['side'] == side for c in candidates)
        counts['affectedLowWalls'] = sum(c['lowCellCount'] for c in candidates if c['side'] == side)
        inventories[side] = dict(counts)
    # Inputs are pinned before and after scanning, including archived provenance.
    assert all(sha(args.assets / f'{name}_svg_height_{s}.json.gz') == digest for s, digest in asset_hashes.items())
    assert sha(profile_path) == profile_hash and sha(alignment_path) == alignment_hash
    report = dict(map=name, status='inventoried', algorithmSha256=sha(Path(__file__)),
                  assetSha256=asset_hashes, profilePath=str(profile_path), profileSha256=profile_hash,
                  alignmentPath=str(alignment_path), alignmentSha256=alignment_hash,
                  profileRecords=len(profile['records']), profileStations=sum(map(len, stations.values())),
                  inventory=inventories, candidates=candidates)
    (args.output / f'{name}.json').write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(dict(map=name, inventory=inventories)), flush=True)
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--assets', type=Path, default=Path('assets/maps'))
    parser.add_argument('--profile-root', type=Path, default=ROOT / 'tactical-visibility-revision/all-map-finite-heights-v7')
    parser.add_argument('--alignment-root', type=Path, default=ROOT / 'tactical-alignment-sides-v1')
    parser.add_argument('--output', type=Path, default=Path('work/fracture-wall-review-2026-09-14/all-map-height-drops'))
    parser.add_argument('--maps', nargs='*')
    parser.add_argument('--camera-height', type=float, default=1.75)
    parser.add_argument('--adjacency-svg', type=float, default=.001)
    parser.add_argument('--cap-tolerance', type=float, default=.04)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    names = args.maps or sorted(p.name.removesuffix('_svg_height_attack.json.gz') for p in args.assets.glob('*_svg_height_attack.json.gz'))
    reports = [audit(name, args) for name in names]
    rows = [c for r in reports for c in r['candidates']]
    rows.sort(key=lambda c: ('structural-assembly-review' not in c['classification'], not c['persistentMultipleCells'], -c['maximumAdjacentJumpMeters'], -c['areaSvg']))
    shortlist = [{k: v for k, v in c.items() if k not in ['lowWalls', 'adjacentHighWalls']} for c in rows]
    families = defaultdict(list)
    for c in rows:
        for pair in c['sameSourcePlinthPairs']:
            families[(c['map'], pair['sourceObject'], pair['sourcePath'])].append((c, pair))
    focused = []
    object_caps = defaultdict(list)
    for name in names:
        for record in read(args.profile_root / name / 'local-source-profiles.json')['records']:
            for station in record['stations']:
                top = station.get('measuredTopMeters')
                if top is not None and np.isfinite(top):
                    object_caps[(name, station.get('sourceObject'))].append(top)
    for (name, oid, path), matches in families.items():
        tops = object_caps[(name, oid)]
        low_cap = max(p['lowCapMeters'] for c,p in matches)
        high_fraction = sum(t > low_cap + 2 * args.camera_height for t in tops) / len(tops) if tops else 0.
        # Names only separate review queues; these labels are not gameplay decisions.
        lower_path = (path or '').lower()
        named_kind = ('box-or-prop-name' if re.search(r'box|crate|pallet|statue|prop_|rubble|barrel|rocks_|snow_|ladder', lower_path)
                      else 'floor-or-ramp-name' if re.search(r'floor|ground|ramp|platform|ledge|railing|catwalk', lower_path)
                      else 'vegetation-name' if re.search(r'shrub|foliage|tree', lower_path)
                      else 'structural-or-other-name')
        focused.append(dict(map=name, sourceObject=oid, sourcePath=path,
            sourceNameReviewBucket=named_kind, archivedObjectStationCount=len(tops),
            highStationFraction=high_fraction,
            lowWallCount=len({(c['side'], p['lowWallId']) for c,p in matches}),
            sides=sorted({c['side'] for c,p in matches}),
            parents=sorted({c['parent'] for c,p in matches}),
            maximumAdjacentJumpMeters=max(p['highCapMeters'] - p['lowCapMeters'] for c,p in matches),
            persistentMultipleCells=any(c['persistentMultipleCells'] for c,p in matches),
            evidence=[dict(side=c['side'], parent=c['parent'], **p) for c,p in matches]))
    focused.sort(key=lambda f: (not f['persistentMultipleCells'], -f['lowWallCount'], -f['maximumAdjacentJumpMeters']))
    mechanism_shortlist = [f for f in focused if f['persistentMultipleCells'] and f['lowWallCount'] >= 2
                          and f['highStationFraction'] > .5
                          and f['sourceNameReviewBucket'] == 'structural-or-other-name']
    summary = dict(mapCount=len(reports), sideCount=len(reports)*2,
        algorithmSha256=sha(Path(__file__)), candidateIslands=len(rows),
        thresholds=dict(cameraHeightMeters=args.camera_height, adjacencySvg=args.adjacency_svg, nearEqualCapMeters=args.cap_tolerance),
        classifications=dict(Counter(k for c in rows for k in c['classification'])),
        inventory={r['map']: r['inventory'] for r in reports},
        positiveControlFractureReactor=[c for c in shortlist if c['map']=='fracture' and c['parent']=='p13-stroke-0' and c['lowCapRangeMeters'][0] <= 7.51 and c['highCapRangeMeters'][1] >= 22],
        prioritizedCandidates=shortlist,
        focusedSameSourcePlinthFamilies=focused,
        focusedSameSourcePlinthFamilyCount=len(focused),
        mechanismShortlist=mechanism_shortlist,
        mechanismShortlistCount=len(mechanism_shortlist),
        limitations=[
            'Candidates are numerical cap discontinuities. They do not establish bad gameplay, an opening, or standing eligibility.',
            'Only adjacent finite single-band walls within one authored SVG parent are compared. Other parents and multiband or unbounded walls are inventoried but excluded.',
            'Persistent means connected near-equal cap cells, not a proven enclosed island or temporal persistence. Pairwise cap tolerance may join a gradual slope.',
            'Attack uses the nearest same-parent archived station. Defense uses the nearest station after transformation because parent identifiers differ across artwork sides. These are provenance for review, not proof of complete assembly ownership.',
            'Focused families require matching primary structure object, station distance <=2 SVG units, low cap 0..camera height above archived ground and within .1 m of the archived measured top, and high cap >2 camera heights higher. Archived ground is not a verified current standing support.',
            'Mechanism shortlist additionally requires multiple low cells, majority tall stations on the same source object, and excludes separate name-based box/prop, floor/ramp, and vegetation review queues. Name buckets are heuristic.',
            'Source-role classifications are review buckets. Correct boxes, floor transitions, and height changes can be flagged.',
            'Both artwork sides are reported separately and may describe the same physical source case.'])
    (args.output / 'summary.json').write_text(json.dumps(summary, indent=2)+'\n')
    print(json.dumps({k: summary[k] for k in ['mapCount', 'sideCount', 'candidateIslands', 'classifications']}))


if __name__ == '__main__':
    main()

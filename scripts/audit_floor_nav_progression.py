"""Add connected nav-parent evidence to unclassified floor assemblies."""
import argparse
import collections
import gzip
import json
from pathlib import Path
import numpy as np
import shapely
from audit_navigation_components import native_vertices
from probe_source_floor_regressions import load_support


def augment(name):
    revision = Path('E:/IcarusWorldAudit/2026-09-06/tactical-visibility-revision')
    directory = revision / 'competing-floor-assemblies-v3'
    path = directory / f'{name}.json'
    report = json.loads(path.read_text())
    support = load_support(revision, name, True)
    nav = json.loads(gzip.decompress((revision / f'baseline-world/{name}_navigation.json.gz').read_bytes()))
    ui = json.loads((revision / 'baseline-world/height_catalog.json').read_text())['maps'][name]['uiTransform']
    detail = np.asarray(nav['floorMesh']['triangles']).reshape(-1, 4)
    valid = np.asarray(nav['walkable'])[detail[:, 0]]
    parents = detail[valid, 0]
    nav_ids = support.detailed_navigation_indices
    assert len(nav_ids) == len(parents)
    tree = shapely.STRtree(support.polygons[nav_ids])
    links = np.asarray(nav['links']).reshape(-1, 6)
    portal_uv = (links[:, 2:4] + links[:, 4:6]) / 2 / nav['coordinateScale']
    portal_native = np.column_stack(((portal_uv[:, 1] - ui['YScalarToAdd']) / (100 * ui['YMultiplier']), -(portal_uv[:, 0] - ui['XScalarToAdd']) / (100 * ui['XMultiplier'])))
    for row in report['records']:
        indices = row['admittedSupportIndices']
        samples = np.concatenate([support.points[indices], support.points[indices].mean(axis=1)[:, None]], axis=1).reshape(-1, 3)
        sample_ids, nav_local = tree.query(shapely.points(samples[:, :2]), predicate='intersects')
        predicted = np.sum(samples[sample_ids, :2] * support.planes[nav_ids[nav_local], :2], axis=1) + support.planes[nav_ids[nav_local], 2]
        matches = abs(predicted - samples[sample_ids, 2]) <= .1
        matched_parents = parents[nav_local[matches]]
        matched_z = predicted[matches]
        parent_ids = set(int(i) for i in matched_parents)
        parent_samples = {parent: {'minimum': float(matched_z[matched_parents == parent].min()), 'maximum': float(matched_z[matched_parents == parent].max())} for parent in parent_ids}
        link_ids = np.flatnonzero(np.isin(links[:, 0], list(parent_ids)) & np.isin(links[:, 1], list(parent_ids)))
        footprint = shapely.union_all(support.polygons[indices], grid_size=1e-8).buffer(.1)
        link_ids = link_ids[shapely.intersects(shapely.points(portal_native[link_ids]), footprint)]
        adjacency = collections.defaultdict(set)
        for index in link_ids:
            a, b = map(int, links[index, :2]); adjacency[a].add(b); adjacency[b].add(a)
        unseen = set(parent_ids)
        components = []
        while unseen:
            start = min(unseen)
            queue = [start]; selected = set()
            while queue:
                parent = queue.pop()
                if parent in selected:
                    continue
                selected.add(parent); queue.extend(adjacency[parent] - selected)
            unseen -= selected
            minimum_parent = min(selected, key=lambda p: parent_samples[p]['minimum'])
            maximum_parent = max(selected, key=lambda p: parent_samples[p]['maximum'])
            queue = collections.deque([minimum_parent]); previous = {minimum_parent: None}
            while queue:
                current = queue.popleft()
                if current == maximum_parent:
                    break
                for other in sorted(adjacency[current]):
                    if other not in previous:
                        previous[other] = current; queue.append(other)
            route = [maximum_parent]
            while previous[route[-1]] is not None:
                route.append(previous[route[-1]])
            route.reverse()
            minimum, maximum = parent_samples[minimum_parent]['minimum'], parent_samples[maximum_parent]['maximum']
            components.append({'parents': sorted(selected), 'heightRangeMeters': [minimum, maximum], 'heightSpanMeters': maximum - minimum, 'parentRoute': [{'parent': parent, 'matchedHeightRangeMeters': [parent_samples[parent]['minimum'], parent_samples[parent]['maximum']]} for parent in route]})
        components.sort(key=lambda c: c['heightSpanMeters'], reverse=True)
        span = components[0]['heightSpanMeters'] if components else 0.
        row['connectedNavProgression'] = {'scope': 'Source-refined detailed-nav parents matched to source vertices/centroids within10cm. These heights are source-correlated, not independent game walkability evidence. Graph uses existing nav links whose portal midpoint is inside the assembly support footprint plus10cm. Connectivity is evidence for review, not a terrain role or proof of monotonic ascent.', 'componentCount': len(components), 'maximumConnectedHeightSpanMeters': span, 'components': components}
        row['reviewPriority'] = 'connected-rising-nav-overlap' if span >= .25 and row['overlapFootprintAreaUpperBoundMeters2'] >= .1 else 'low-or-disconnected-overlap'
    report['records'].sort(key=lambda row: (row['reviewPriority'] == 'connected-rising-nav-overlap', row['connectedNavProgression']['maximumConnectedHeightSpanMeters'], row['overlapFootprintAreaUpperBoundMeters2']), reverse=True)
    path.write_text(json.dumps(report, indent=2))
    print(name, 'connected progression candidates', sum(row['reviewPriority'] == 'connected-rising-nav-overlap' for row in report['records']), flush=True)


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('maps', nargs='+')
    args = parser.parse_args()
    for name in args.maps:
        augment(name)

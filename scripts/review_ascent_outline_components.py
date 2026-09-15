"""Inventory complete Ascent outline components without declaring unknown contacts solid."""
import gzip
import json
from collections import Counter
from pathlib import Path

import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
import numpy as np
from native_compact_wall_profiles import sha
from prepare_ascent_connected_corners import ROOT, REV, OUT, frame
from tactical_alignment_composite import explicit_warp


def main():
    coverage_path = REV/'all-map-wall-span-coverage-v1/ascent/attack.coverage.json.gz'
    coverage = json.loads(gzip.decompress(coverage_path.read_bytes()))
    raw_path = ROOT/'supplemented-v2/world/ascent/geometry.npz'
    raw = np.load(raw_path)
    points, faces = raw['points'], raw['faces']
    meta = json.loads(raw_path.with_suffix('.json').read_text())
    warp_path = REV/'display-warps-v1/ascent.display-warp.json.gz'
    w = json.loads(gzip.decompress(warp_path.read_bytes()))
    matrix = np.column_stack((w['projection']['axisU'], w['projection']['axisV']))
    origin = np.array(w['projection']['origin'])
    source_svg = np.array(w['sourceNativeMeters']).reshape(-1, 2) @ matrix.T + origin
    target_svg = np.array(w['targetAttackSvg']).reshape(-1, 2)
    warp = explicit_warp(source_svg, target_svg-source_svg, np.array(w['triangles']).reshape(-1, 3))
    known = json.loads((OUT/'connected-proposals.json').read_text())
    approved = {f['edge']: f for chain in known['chains'] for f in chain['families']}
    object_cache = {}
    packet_triangles, packet_faces, packet_candidates = [], [], []
    components = []
    for subpath in [5, 7]:
        spans = [s for s in coverage['spans'] if s['subpath'] == subpath]
        rows = []
        for span in spans:
            span_id = span['span']
            target_frame, length = frame(span['startSvg'], span['endSvg'])
            tangent = np.array(target_frame['tangent'])
            target_normal = np.array(target_frame['normal'])
            samples = [s for s in coverage['samples'] if s['span'] == span_id and s.get('probeStartInsideReceiver')]
            valid = [s for s in samples if s.get('originalSourceFace') is not None]
            groups = []
            for sample in valid:
                fid, obj = sample['originalSourceFace'], sample['sourceObjectIndex']
                triangle = points[faces[fid]].copy()
                triangle[:, :2] = triangle[:, :2] @ matrix.T + origin
                normal = np.cross(triangle[1]-triangle[0], triangle[2]-triangle[0])
                norm = np.linalg.norm(normal[:2])
                if norm == 0:
                    continue
                normal /= norm
                if abs(normal[2]) > .005 or abs(normal[:2] @ target_normal) < .9999:
                    continue
                if normal[:2] @ target_normal < 0:
                    normal = -normal
                offset = float((triangle[:, :2] @ normal[:2]).mean())
                group = next((g for g in groups if g['sourceObjectIndex'] == obj and abs(g['offset']-offset) < .001 and np.dot(g['normal'], normal[:2]) > .999999), None)
                if group is None:
                    group = dict(sourceObjectIndex=obj, normal=normal[:2].tolist(), offset=offset, seedFaces=[], sampleIndices=[], standingPositions=[])
                    groups.append(group)
                group['seedFaces'].append(fid)
                group['sampleIndices'].append(sample['samplePosition'])
                if sample['relativeEyeHeightMeters'] == 1.75:
                    group['standingPositions'].append(sample['samplePosition'])
            groups.sort(key=lambda g: (-len(set(g['standingPositions'])), -len(g['sampleIndices'])))
            for index, group in enumerate(groups):
                obj = group['sourceObjectIndex']
                if obj not in object_cache:
                    ob = meta['objects'][obj]
                    ids = np.arange(ob['firstFace'], ob['firstFace']+ob['faceCount'])
                    triangles = points[faces[ids]].copy()
                    triangles[:, :, :2] = triangles[:, :, :2] @ matrix.T + origin
                    normals = np.cross(triangles[:, 1]-triangles[:, 0], triangles[:, 2]-triangles[:, 0])
                    normals /= np.maximum(np.linalg.norm(normals, axis=1)[:, None], 1e-30)
                    object_cache[obj] = ids, triangles, normals
                ids, triangles, normals = object_cache[obj]
                n = np.array(group['normal'])
                # This tolerance inventories near-plane faces. It does not authorize
                # moving them, nor fill the differences between their actual planes.
                near = (np.max(abs(triangles[:, :, :2] @ n-group['offset']), axis=1) < .001)
                near &= (abs(normals[:, :2] @ n) > .99999) & (abs(normals[:, 2]) < .005)
                selected, xyz = ids[near], triangles[near]
                start = len(packet_faces)
                packet_faces.extend(selected.tolist())
                packet_triangles.extend(xyz.tolist())
                packet_candidates.extend([[span_id, index]]*len(selected))
                group.update(candidate=index, sourceObjectPath=meta['objects'][obj]['path'], sourceFaces=selected.tolist(), packetRows=[start, len(packet_faces)], seedFaces=sorted(set(group['seedFaces'])), standingPositions=sorted(set(group['standingPositions'])), sampleIndices=sorted(set(group['sampleIndices'])), sourceAlongBounds=[float((xyz[:, :, :2] @ tangent).min()), float((xyz[:, :, :2] @ tangent).max())] if len(xyz) else None, originalZBounds=[float(xyz[:, :, 2].min()), float(xyz[:, :, 2].max())] if len(xyz) else None, inventoryToleranceSvg=.001, disposition='Unreviewed source-plane candidate; preserve original source fragments until finite ownership and openings are reviewed.')
            flags = []
            if not groups:
                flags.append('no-aligned-contact-plane')
            if len(groups) > 1:
                flags.append('multiple-source-depth-or-object-candidates')
            if len(valid) < len(samples):
                flags.append('some-probes-have-no-source-contact')
            if any(s.get('masked') for s in valid):
                flags.append('masked-source-contact')
            rows.append(dict(span=span_id, legacyStraightEdgeIndex=span['legacyStraightEdgeIndex'], targetEndpoints=[span['startSvg'], span['endSvg']], targetFrame=target_frame, targetAlong=[0., length], candidates=groups, knownApprovedPrimary=approved.get(span_id), samples=samples, flags=flags, sourceObjectContactCounts=dict(Counter(str(s['sourceObjectIndex']) for s in valid))))
        joins = []
        for left, right in zip(rows, rows[1:]+rows[:1]):
            assert left['targetEndpoints'][1] == right['targetEndpoints'][0]
            record = dict(betweenSpans=[left['span'], right['span']], targetSvg=left['targetEndpoints'][1], status='unresolved')
            if left['candidates'] and right['candidates']:
                a, b = left['candidates'][0], right['candidates'][0]
                equations = np.array([a['normal'], b['normal']])
                if abs(np.linalg.det(equations)) > 1e-8:
                    xy = np.linalg.solve(equations, [a['offset'], b['offset']])
                    display = warp.apply(xy[None])[0]
                    record.update(sourceSvg=xy.tolist(), originalDisplayedSvg=display.tolist(), displayedDisplacementSvg=float(np.linalg.norm(display-record['targetSvg'])), candidatePair=[0, 0], status='plane-intersection-proposal-only; exact height/cap/finite-ownership review required')
            joins.append(record)
        components.append(dict(subpath=subpath, closed=True, spans=rows, joins=joins, acceptance='Complete outline inventory only. Candidate rank is observed contact frequency, not semantic wall classification.'))
        fig, axes = plt.subplots(1, 2, figsize=(15, 8))
        for row in rows:
            target = np.array(row['targetEndpoints'])
            axes[0].plot(*target.T, color='#212529', lw=1.5)
            axes[0].text(*target.mean(0), str(row['span']), fontsize=8, color='#005f73')
            for candidate in row['candidates'][:1]:
                a, b = candidate['packetRows']
                triangles = np.array(packet_triangles[a:b])
                for tri in triangles:
                    axes[1].plot(*np.vstack((tri[:, :2], tri[:1, :2])).T, lw=.25, alpha=.2, color='#0077b6')
            axes[1].plot(*target.T, color='#e76f51', lw=1.3)
        for ax in axes:
            ax.set_aspect('equal')
            ax.invert_yaxis()
        axes[0].set_title('Complete authored outline; all joins included')
        axes[1].set_title('Dominant contact source planes in blue; SVG in orange')
        bounds = np.array([r['targetEndpoints'] for r in rows]).reshape(-1, 2)
        for ax in axes:
            ax.set_xlim(bounds[:, 0].min()-5, bounds[:, 0].max()+5)
            ax.set_ylim(bounds[:, 1].max()+5, bounds[:, 1].min()-5)
        fig.suptitle(f'Ascent component {subpath}: source candidates only; no normalized geometry')
        fig.tight_layout()
        fig.savefig(OUT/f'component-{subpath}-source-plan.png', dpi=180)
        plt.close(fig)
    packet = OUT/'component-source-faces.npz'
    np.savez_compressed(packet, sourceFaces=np.array(packet_faces, dtype=np.int64), sourceTrianglesSvgZ=np.array(packet_triangles), spanCandidate=np.array(packet_candidates, dtype=np.int64))
    report = dict(format='icarus-complete-outline-source-review-v1', map='ascent', components=components, packet=str(packet), packetSha256=sha(packet), sourceGeometrySha256=meta['geometrySha256'], sourceFileSha256=sha(raw_path), coverageSha256=sha(coverage_path), displayWarpSha256=sha(warp_path), approvedPrimaryProposalSha256=sha(OUT/'connected-proposals.json'), scriptSha256=sha(Path(__file__)), productionMutation=False)
    (OUT/'component-proposals.json').write_text(json.dumps(report, indent=2)+'\n')
    summary = [dict(subpath=c['subpath'], spans=len(c['spans']), candidates=sum(len(s['candidates']) for s in c['spans']), unbound=sum(not s['candidates'] for s in c['spans']), unresolvedJoinPlanes=sum('sourceSvg' not in j for j in c['joins'])) for c in components]
    print(json.dumps(summary, indent=2))


if __name__ == '__main__':
    main()

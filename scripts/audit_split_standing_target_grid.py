"""Replay frozen Split eyes against source-supported standing targets.

Compare the current constant-relative-Z policy with straight eye-to-head rays.
Every clear source-floor candidate at a point is tested; differing outcomes stay
unresolved. These finite navigation samples do not render a replacement cone.
"""
import json
from pathlib import Path
import numpy as np
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
from matplotlib.collections import LineCollection

from build_global_tactical_candidate import GroundField
from native_reference_cast import NativeReferenceModel
from probe_real_receiver_room_controls import in_cone, sha
from tactical_alignment_audit import vector_lines


def main():
    r = Path('E:/IcarusWorldAudit/2026-09-06/tactical-visibility-revision')
    out = r/'split-standing-target-grid-v1'
    out.mkdir(exist_ok=False)
    scene_path = r/'frozen-split-app-scene-v29-run1/manifest.json'
    scene = json.loads(scene_path.read_bytes())
    queries = next(row['sourceQueries'] for row in scene['records'] if row['side']=='attack')
    config = json.loads(Path(scene['configPath']).read_bytes())['maps']['split']
    ground = GroundField(config['groundFieldFile'])
    column_path = r/'split-nav-source-floor-clearance-v1/candidate-columns.npz'
    with np.load(column_path) as data:
        samples, svg = data['samples'], data['displayedSvg']
        sid, z, clear = data['sampleIds'], data['sourceHeights'], data['centerColumnClear']==1
    heights = {}
    for i, height in zip(sid[clear], z[clear]):
        heights.setdefault(int(i), set()).add(float(height))
    original_pack = r/'split-complete-control-original-height-v29-v2/split.height.bin.gz'
    flat_pack = r/'split-wall-family-normalized-candidate-v29/split.height.bin.gz'
    dll = r/'native-tactical-rays-build/Release/tactical_reference_cast.dll'
    original, flat = NativeReferenceModel(original_pack, dll), NativeReferenceModel(flat_pack, dll)
    rows = []
    for index, name in [(4,'Clove'), (6,'Iso'), (7,'Viper')]:
        q = np.asarray(queries[index]); eye = q[:3].copy()
        eye[2] += ground.heights(q[None,:2])[0]
        controls = []
        offered = np.flatnonzero(in_cone(samples[:,:2], q))
        for i in offered:
            if int(i) not in heights:
                continue
            xy = samples[i,:2]
            flat_hit = flat.cast(q[:3], np.r_[xy,q[2]])
            hypotheses = []
            for height in sorted(heights[int(i)]):
                feet = np.r_[xy,height]; target = feet+[0,0,1.75]
                # The column was qualified in original raw XY. Recheck it in
                # the wall-normalized comparison scene before treating it as
                # a usable target for this particular diagnostic.
                column_hit = original.cast(feet+[0,0,.0001], target)
                hit = original.cast(eye, target)
                hypotheses.append(dict(floorHeight=height, target=target.tolist(),
                    normalizedColumnHit=column_hit, standingHeadHit=hit))
            valid = [h for h in hypotheses if h['normalizedColumnHit'] is None]
            outcomes = {h['standingHeadHit'] is None for h in valid}
            state = 'unresolved'
            if len(outcomes)==1:
                head_clear = next(iter(outcomes))
                state = ('gained' if head_clear else 'lost') if head_clear != (flat_hit is None) else 'unchanged'
            controls.append(dict(sample=int(i), nativeNavigationFeet=samples[i].tolist(),
                displayedSvg=svg[i].tolist(), currentRelativeHeightHit=flat_hit,
                sourceFloorHypotheses=hypotheses, comparison=state))
        summary = {key:sum(c['comparison']==key for c in controls) for key in ['gained','lost','unchanged','unresolved']}
        row = dict(agent=name, query=q.tolist(), originalEye=eye.tolist(),
                   offeredInsideCone=len(offered), unsupportedSamples=len(offered)-len(controls),
                   controls=controls, summary=summary)
        rows.append(row)
        print(name,summary,'unsupported',row['unsupportedSamples'],flush=True)
        fig, ax = plt.subplots(figsize=(9,9))
        for line in vector_lines(Path('assets/maps/split_map.svg')):
            ax.plot(*line.T,color='#b38a51',linewidth=.75)
        for kind,color,size in [('unchanged','#7c8590',7),('gained','#13946a',22),
                                ('lost','#c94746',22),('unresolved','#c48b22',22)]:
            points = np.asarray([c['displayedSvg'] for c in controls if c['comparison']==kind]).reshape(-1,2)
            if len(points): ax.scatter(*points.T,s=size,color=color,label=f'{kind}: {len(points)}',zorder=3)
        points=np.asarray([c['displayedSvg'] for c in controls])
        if len(points):
            low, high = points.min(0)-20, points.max(0)+20
            ax.set_xlim(low[0],high[0]);ax.set_ylim(high[1],low[1])
        ax.set_aspect('equal');ax.legend(loc='best');ax.grid(alpha=.12)
        ax.set_title(f'{name}: standing head targets versus current relative-height section\n'
                     'Point samples on actual SVG. Unsupported floors omitted. No replacement cone rendered.',fontsize=11)
        fig.tight_layout();fig.savefig(out/f'{name.lower()}-target-policy-samples.png',dpi=150);plt.close(fig)
    report = dict(scope=__doc__, rows=rows, sceneSha256=sha(scene_path),
        sourceFloorColumnsSha256=sha(column_path), originalHeightPackSha256=sha(original_pack),
        relativeHeightPackSha256=sha(flat_pack), groundFieldSha256=sha(Path(config['groundFieldFile'])),
        scriptSha256=sha(Path(__file__)), nativeLibrarySha256=sha(dll),
        pythonCasterSha256=sha(Path(__file__).with_name('native_reference_cast.py')),
        limitations=['Uses frozen V29 geometry for both policies. It does not include subsequent wall alignment fixes.',
            'Eye heights retain the existing frozen navigation-based placements.',
            'Floor center-column clearance does not certify Pawn collision or a full capsule.',
            'Mixed floor hypotheses and missing source support remain unresolved.',
            'This is source ray evidence, not a runtime mesh or live-game comparison.'])
    (out/'report.json').write_text(json.dumps(report,indent=2)+'\n')


if __name__ == '__main__':
    main()

"""Proposal to preserve the omitted catwalk wall and attached I-beam together."""
import gzip
import json
import numpy as np
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
from matplotlib.collections import LineCollection
from build_split_connected_tower import REV
from declare_split_component7_region import declarations as original_declaration
from declare_split_component2_cover_region import grid
from build_split_normalized_wall_families import cut
from authored_region_cells import region_fragments
from tactical_alignment_composite import explicit_warp
from render_split_remaining_corner_families import sections


def declaration():
    family = original_declaration()
    packet = np.load(REV / 'split-component7-catwalk-join-review-v1/hostel-catwalk-join-full-source.npz')
    selected = np.isin(packet['sourceObjectIds'], [6948,6994])
    family['reviewedSourceFaces'] = sorted(set(family['reviewedSourceFaces']) | set(packet['sourceFaceIds'][selected].tolist()))
    family['objects'] = sorted(set(family['objects']) | {6948,6994})
    band = next(b for b in family['sourceProfileBands']['x'] if b['spans'] == [200])
    band['source'][1] = 115.61429924601612
    band['reviewedAddition'] = 'Proposal: catwalk wall6948 and attached I-beam6994 retain their original Z profiles. Lower source opening remains open.'
    def knots(bands, lower, upper):
        points = {lower:lower, upper:upper}
        for entry in bands:
            for value in entry['source']: points[value] = entry['target']
        source = sorted(points)
        return source, [points[value] for value in source]
    xs,tx = knots(family['sourceProfileBands']['x'],88.,185.)
    ys,ty = knots(family['sourceProfileBands']['y'],100.,185.5)
    family.update(grid(xs,ys,lambda x,y:[float(np.interp(x,xs,tx)),float(np.interp(y,ys,ty))]))
    family['status'] = 'Catwalk continuation proposal only; no bake before source review.'
    return family


def main():
    out = REV / 'split-component7-connected-region-proposal-v2'
    out.mkdir(exist_ok=True)
    family = declaration()
    (out / 'region-declaration.json').write_text(json.dumps(family,indent=2))
    packet = np.load(REV / 'split-component7-catwalk-join-review-v1/hostel-catwalk-join-full-source.npz')
    original = packet['trianglesSvgSourceZ']
    w = json.loads(gzip.decompress((REV / 'display-warps-v1/split.display-warp.json.gz').read_bytes()))
    matrix = np.column_stack((w['projection']['axisU'],w['projection']['axisV']))
    source = np.array(w['sourceNativeMeters']).reshape(-1,2) @ matrix.T + w['projection']['origin']
    target = np.array(w['targetAttackSvg']).reshape(-1,2)
    unwarp = explicit_warp(target,source-target,np.array(w['triangles']).reshape(-1,3))
    mapped = []
    for tri in original:
        inside,outside = cut(list(np.column_stack((tri,np.eye(3)))),family['box'])
        parts = [np.array(part) for part in outside]
        if len(inside) >= 3: parts.extend(p for p,_,_ in region_fragments(np.array(inside),family,unwarp))
        for part in parts:
            mapped.extend(part[[0,j,j+1],:3] for j in range(1,len(part)-1))
    mapped = np.array(mapped)
    fig,axes = plt.subplots(1,4,figsize=(18,8))
    for ax,z in zip(axes,[7.25,8.25,9.75,11.75]):
        for mesh,color,label in [(original,'#dc2626','Original source'),(mapped,'#16a34a','Connected proposal')]:
            lines,_ = sections(mesh,z)
            ax.add_collection(LineCollection(lines,colors=color,lw=1.2,label=label))
        for span in family['reviewedAuthoredSpans']: ax.plot(*np.array([span['startSvg'],span['endSvg']]).T,color='#111827',lw=1.2)
        ax.set_xlim(108,124); ax.set_ylim(145,128); ax.set_aspect('equal'); ax.grid(alpha=.2)
        ax.set_title(f'Absolute source Z={z:g}m'); ax.legend(fontsize=8)
    fig.suptitle('Catwalk continuation proposal. Original lower opening remains; upper catwalk and attached I-beam share span200 datum.\nSections include exact source height profiles. No pack bake.')
    fig.tight_layout(rect=[0,0,1,.94]); fig.savefig(out / 'catwalk-connected-source-profile-preview.png',dpi=160); plt.close(fig)
    print(out)


if __name__ == '__main__':
    main()

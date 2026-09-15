"""Raw 169–172 source profiles and unfiltered neighboring object inventory."""
import gzip,json
from pathlib import Path
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
from matplotlib.collections import LineCollection
import numpy as np
from tactical_alignment_audit import vector_lines
from render_split_remaining_corner_families import sections
from lift_reviewed_wall_source_heights import sha

ROOT=Path('E:/IcarusWorldAudit/2026-09-06');REV=ROOT/'tactical-visibility-revision'
out=REV/'split-upper-vent-chain-source-review-v1';out.mkdir(exist_ok=False)
wp=REV/'display-warps-v1/split.display-warp.json.gz';w=json.loads(gzip.decompress(wp.read_bytes()))
matrix=np.column_stack((w['projection']['axisU'],w['projection']['axisV']));origin=np.array(w['projection']['origin'])
raw=ROOT/'supplemented-v2/world/split/geometry.npz';d=np.load(raw);points,faces=d['points'],d['faces'];meta=json.loads(raw.with_suffix('.json').read_text())
obj=meta['objects'][5927];ids=np.arange(obj['firstFace'],obj['firstFace']+obj['faceCount']);tri=points[faces[ids]].copy();tri[:,:,:2]=tri[:,:,:2]@matrix.T+origin
art=vector_lines(Path('assets/maps/split_map.svg'));zs=[4.35,6.5,6.8,8.35,12.75,17.9]
fig,axes=plt.subplots(2,3,figsize=(17,11));records=[]
for ax,z in zip(axes.flat,zs):
    source,parent=sections(tri,z);ax.add_collection(LineCollection(source,colors='#dc2626',lw=.8))
    for line in art:
        if (line.max(0)>[270,96]).all() and (line.min(0)<[309,186]).all():ax.plot(*line.T,color='#111827',lw=1.3)
    ax.set(xlim=(270,309),ylim=(186,96),title=f'Original absolute Z {z} m');ax.set_aspect('equal');ax.grid(alpha=.15)
    records.append(dict(z=z,segments=[dict(rawFace=int(ids[i]),points=line.tolist()) for line,i in zip(source,parent)]))
fig.suptitle('Black: unchanged attack SVG. Red: raw source 5927 in the original attack projection. No correction or W.');fig.tight_layout();fig.savefig(out/'six-heights-raw-source.png',dpi=145);plt.close(fig)
neighbors=[]
for index,obj in enumerate(meta['objects']):
    t=points[faces[obj['firstFace']:obj['firstFace']+obj['faceCount']]]
    xy=t[:,:,:2]@matrix.T+origin
    if len(t) and (xy.max((0,1))>=[270,96]).all() and (xy.min((0,1))<=[309,186]).all():
        neighbors.append(dict(index=index,path=obj['path'],firstFace=obj['firstFace'],faceCount=obj['faceCount'],boundsSvg=[xy.min((0,1)).tolist(),xy.max((0,1)).tolist()],z=[float(t[:,:,2].min()),float(t[:,:,2].max())]))
(out/'source-sections-and-inventory.json').write_text(json.dumps(dict(sourceSha256=sha(raw),scriptSha256=sha(Path(__file__)),sections=records,unfilteredNeighbors=neighbors),indent=2)+'\n')
print(json.dumps(dict(output=str(out),neighbors=len(neighbors))))

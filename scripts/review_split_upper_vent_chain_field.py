"""Source profiles and exact finite segment contacts of the held upper chain."""
import gzip,json
from pathlib import Path
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
from matplotlib.collections import LineCollection
import numpy as np
import shapely
from authored_region_cells import barycentric
from tactical_alignment_composite import explicit_warp
from tactical_alignment_audit import vector_lines
from render_split_remaining_corner_families import sections
from verify_region_contact import segment_cells,interval_values
from lift_reviewed_wall_source_heights import sha

ROOT=Path('E:/IcarusWorldAudit/2026-09-06');REV=ROOT/'tactical-visibility-revision'
out=REV/'split-upper-vent-chain-field-proposal-v2';path=out/'held-region-declaration.json';f=json.loads(path.read_text())
s=np.array(f['sourceVerticesSvg']);t=np.array(f['targetVerticesSvg']);c=np.array(f['triangles']);polys=shapely.polygons(s[c]);tree=shapely.STRtree(polys);domain=shapely.union_all(polys)
wp=REV/'display-warps-v1/split.display-warp.json.gz';w=json.loads(gzip.decompress(wp.read_bytes()));m=np.column_stack((w['projection']['axisU'],w['projection']['axisV']));o=np.array(w['projection']['origin'])
ws=np.array(w['sourceNativeMeters']).reshape(-1,2)@m.T+o;wt=np.array(w['targetAttackSvg']).reshape(-1,2);wc=np.array(w['triangles']).reshape(-1,3);forward=explicit_warp(ws,wt-ws,wc)
raw=ROOT/'supplemented-v2/world/split/geometry.npz';d=np.load(raw);p=d['points'];faces=d['faces'];tri=p[faces[f['reviewedSourceFaces']]].copy();tri[:,:,:2]=tri[:,:,:2]@m.T+o
def mapped(lines):
    result=[]
    for line in lines:
        segment=shapely.LineString(line)
        for cell in tree.query(segment,predicate='intersects'):
            for part in shapely.get_parts(shapely.intersection(segment,polys[cell])):
                if part.geom_type=='LineString' and part.length>0:result.append(barycentric(np.array(part.coords),s[c[cell]])@t[c[cell]])
        for part in shapely.get_parts(shapely.difference(segment,domain)):
            if part.geom_type=='LineString' and part.length>0:result.append(forward.apply(np.array(part.coords)))
    return result
art=vector_lines(Path('assets/maps/split_map.svg'))
for name,box in [('full-chain',[274,99,307,174]),('172-return',[274,164,302,173]),('171-panel',[295,139,304,172]),('169-start',[277,99,286,114])]:
    fig,axes=plt.subplots(2,3,figsize=(16,10))
    for ax,z in zip(axes.flat,[4.35,6.5,6.8,8.35,12.75,17.9]):
        ss,_=sections(tri,z)
        for line in art:
            if(line.max(0)>=box[:2]).all()and(line.min(0)<=box[2:]).all():ax.plot(*line.T,color='#111827',lw=2.2)
        ax.add_collection(LineCollection([forward.apply(line)for line in ss],colors='#dc2626',lw=.7))
        ax.add_collection(LineCollection(mapped(ss),colors='#16a34a',lw=.9))
        ax.set(xlim=(box[0],box[2]),ylim=(box[3],box[1]),title=f'Original absolute Z {z} m');ax.set_aspect('equal');ax.grid(alpha=.15)
    fig.suptitle('Black: unchanged SVG. Red: prior W source. Green: held finite chain. Raw source heights retained.\nSource sections only: no alpha sampling, first-hit competition, or application render.');fig.tight_layout(rect=[0,0,1,.94]);fig.savefig(out/f'{name}-source-six-heights.png',dpi=145);plt.close(fig)
checks=[]
for name,line,axis,fixed in [
    ('169 full front',[[281.2456633563162,101.03733535613882],[281.2456633563162,142.08822894287403]],0,281.201),
    ('170 full front',[[281.2456633563162,142.08822894287403],[298.82220615672895,142.08822894287403]],1,141.87),
    ('171 full front',[[298.82220615672895,142.08822894287403],[298.82220615672895,169.4555708754589]],0,298.744),
    ('172 full original front',[[275.38123294219076,169.4555708754589],[298.82220615672895,169.4555708754589]],1,168.451)]:
    ss=segment_cells(f,np.array(line));errors=[]
    for a,b in zip(ss[-1][:-1],ss[-1][1:]):errors.append(float(abs(interval_values(ss,a,b)[:,:,axis]-fixed).max()))
    checks.append(dict(name=name,sourceSegment=line,normalAxis=axis,authoredFixed=fixed,affineIntervals=len(errors),maximumNormalErrorSvg=max(errors)))
(out/'source-contact-review.json').write_text(json.dumps(dict(declarationSha256=sha(path),sourceSha256=sha(raw),scriptSha256=sha(Path(__file__)),contacts=checks,status='Held source contact diagnostics. No partition or first-hit acceptance.'),indent=2)+'\n')
print(json.dumps(checks))

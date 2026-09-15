"""Source-section review of the held vent room experiment, not an app render."""
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


def main():
    out=REV/'split-vent-room-finite-field-experiment-v5'
    path=out/'held-region-declaration.json';f=json.loads(path.read_text())
    source=np.array(f['sourceVerticesSvg']);target=np.array(f['targetVerticesSvg']);cells=np.array(f['triangles'])
    polygons=shapely.polygons(source[cells]);tree=shapely.STRtree(polygons);domain=shapely.union_all(polygons)
    wp=REV/'display-warps-v1/split.display-warp.json.gz';w=json.loads(gzip.decompress(wp.read_bytes()))
    matrix=np.column_stack((w['projection']['axisU'],w['projection']['axisV']));origin=np.array(w['projection']['origin'])
    ws=np.array(w['sourceNativeMeters']).reshape(-1,2)@matrix.T+origin;wt=np.array(w['targetAttackSvg']).reshape(-1,2)
    forward=explicit_warp(ws,wt-ws,np.array(w['triangles']).reshape(-1,3))
    raw_path=ROOT/'supplemented-v2/world/split/geometry.npz';data=np.load(raw_path)
    points,faces=data['points'],data['faces'];ids=np.array(f['reviewedSourceFaces']);tri=points[faces[ids]].copy()
    tri[:,:,:2]=tri[:,:,:2]@matrix.T+origin
    def mapped_lines(lines):
        result=[]
        for line in lines:
            segment=shapely.LineString(line)
            for cell in tree.query(segment,predicate='intersects'):
                for part in shapely.get_parts(shapely.intersection(segment,polygons[cell])):
                    if isinstance(part,shapely.LineString) and part.length>0:
                        result.append(barycentric(np.array(part.coords),source[cells[cell]])@target[cells[cell]])
            for part in shapely.get_parts(shapely.difference(segment,domain)):
                if isinstance(part,shapely.LineString) and part.length>0:result.append(forward.apply(np.array(part.coords)))
        return result
    lines=vector_lines(Path('assets/maps/split_map.svg'))
    for name,box in [('173-and-174',[253.,166.,286.,213.]),('175-176-left-interface',[248.,180.,258.,199.]),
                     ('full-lower-room',[208.,166.,288.,214.]),('standing-tip',[262.7,195.4,264.3,197.3])]:
        fig,axes=plt.subplots(2,3,figsize=(17,10))
        for ax,z in zip(axes.flat,[2.65,4.35,6.5,8.25,12.75,15.75]):
            for line in lines:
                if (line.max(0)>=box[:2]).all() and (line.min(0)<=box[2:]).all():ax.plot(*line.T,color='#111827',lw=2.5)
            ss,_=sections(tri,z)
            ax.add_collection(LineCollection([forward.apply(s) for s in ss],colors='#dc2626',lw=.9,label='Raw source with display W'))
            ax.add_collection(LineCollection(mapped_lines(ss),colors='#16a34a',lw=1.1,label='Held field section'))
            ax.set(xlim=(box[0],box[2]),ylim=(box[3],box[1]));ax.set_aspect('equal');ax.grid(alpha=.15)
            ax.set_title(f'Original absolute Z {z:.2f} m');ax.legend(fontsize=7,loc='lower left')
        fig.suptitle('Held source-only experiment. Black is the unchanged SVG wall. No source height or opening is filled.\n'
                     'This does not include candidate first-hit competition, alpha sampling or application rendering.',fontsize=11)
        fig.tight_layout(rect=[0,0,1,.95]);fig.savefig(out/f'{name}-six-height-preview.png',dpi=145);plt.close(fig)
    controls=[('173 return',[[263.65238702795784,169.45555596144112],[263.65238702795784,196.84701386077114]],0,263.657),
        ('173 recessed panel',[[261.58372327820786,170.72480145734528],[261.58372327820786,181.83066691375313]],0,263.657),
        ('174 header',[[255.80903050904556,196.84701386077114],[263.62827106121273,196.84701386077114]],1,196.096),
        ('175 lower wall',[[255.80903050904556,183.1633428944787],[255.80903050904556,196.84701386077114]],0,256.214),
        ('176 lower wall',[[213.45656076289248,183.1633428944787],[255.80903050904556,183.1633428944787]],1,182.274),
        ('172 lower room',[[264.11541509877037,169.45555596144112],[281.02095268433897,169.45555596144112]],1,168.451),
        ('125 lower room',[[235.65405673577322,210.50658377433626],[281.2456484422984,210.50658377433626]],1,210.45)]
    checks=[]
    for name,line,axis,fixed in controls:
        ss=segment_cells(f,np.array(line));error=0.
        for a,b in zip(ss[-1][:-1],ss[-1][1:]):
            q=interval_values(ss,a,b);error=max(error,float(abs(q[:,:,axis]-fixed).max()))
        checks.append(dict(name=name,sourceSegment=line,normalAxis=axis,authoredFixed=fixed,
                           affineIntervals=len(ss[-1])-1,maximumNormalErrorSvg=error))
    report=dict(declarationSha256=sha(path),scriptSha256=sha(Path(__file__)),sourceGeometrySha256=sha(raw_path),
        controls=checks,sourceFaces=len(ids),scope='Continuous normal contact checks of declared finite source segments only. These are not whole-game or original-height visibility controls.',
        held=['No current source-neighbor composition, original-Z ray replay, app render or source partition gate.',
              'The broad 7795 room assignment includes new 176/177/125 source roles and needs independent review.',
              'No field bake is authorized by this diagnostic.'])
    (out/'source-contact-review.json').write_text(json.dumps(report,indent=2)+'\n')
    print(json.dumps(dict(output=str(out),contacts=checks)))


if __name__=='__main__':main()

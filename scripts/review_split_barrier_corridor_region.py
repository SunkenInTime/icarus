"""Raw profile views for the connected construction-wall proposal."""
import json
import numpy as np
import shapely
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
from matplotlib.collections import LineCollection
from build_split_connected_tower import REV
from declare_split_barrier_corridor_region import declaration
from authored_region_cells import barycentric
from render_split_remaining_corner_families import sections


def main(family=None,out=None):
    family=family or declaration();out=out or REV/'split-barrier-corridor-region-proposal-v1';out.mkdir(exist_ok=True)
    (out/'region-declaration.json').write_text(json.dumps(family,indent=2));rows={};owners={}
    wanted=set(family['reviewedSourceFaces'])
    for name in family['sourcePacketFiles']:
        raw=np.load(REV/name)
        for face,obj,tri in zip(raw['sourceFaceIds'],raw['sourceObjectIds'],raw['trianglesSvgSourceZ']):
            if int(face) in wanted:rows[int(face)]=tri;owners[int(face)]=int(obj)
    original=np.array(list(rows.values()));source=np.array(family['sourceVerticesSvg']);target=np.array(family['targetVerticesSvg']);cells=np.array(family['triangles']);polygons=shapely.polygons(source[cells]);tree=shapely.STRtree(polygons)
    def map_lines(lines):
        result=[]
        for endpoints in lines:
            line=shapely.LineString(endpoints)
            for i in tree.query(line,predicate='intersects'):
                for piece in shapely.get_parts(shapely.intersection(line,polygons[i])):
                    if isinstance(piece,shapely.LineString):
                        points=shapely.get_coordinates(piece);mapped=barycentric(points,source[cells[i]])@target[cells[i]]
                        result.extend(np.stack((mapped[:-1],mapped[1:]),axis=1))
        return result
    for name,bounds in [('full-chain',[288,228,345,269]),('mounted-panels-and-return',[320,246,342,268]),('two-diagonal-corners',[291,247,311,267])]:
        fig,axes=plt.subplots(2,2,figsize=(16,13))
        choose=(original[:,:,:2].max(1)>=bounds[:2]).all(1)&(original[:,:,:2].min(1)<=bounds[2:]).all(1);mesh=original[choose]
        for ax,z in zip(axes.flat,[6.75,8.25,9.75,11.75]):
            lines,_=sections(mesh,z)
            for span in family['reviewedAuthoredSpans']:ax.plot(*np.array([span['startSvg'],span['endSvg']]).T,color='#111827',lw=2)
            ax.plot([294.491,294.491],[228,251.917],color='#111827',lw=2)
            ax.add_collection(LineCollection(lines,colors='#dc2626',lw=1,label='Raw source'))
            ax.add_collection(LineCollection(map_lines(lines),colors='#16a34a',lw=1.2,label='Connected field proposal'))
            ax.set_xlim(bounds[0],bounds[2]);ax.set_ylim(bounds[3],bounds[1]);ax.set_aspect('equal');ax.grid(alpha=.15);ax.set_title(f'Original absolute Z {z:g} m');ax.legend(fontsize=8)
        fig.suptitle('Connected barrier125/124/123/122 proposal, original height profiles retained.\nBlack: authored line. Finite upper125 transition remains outside acceptance. No candidate bake.');fig.tight_layout(rect=[0,0,1,.95]);fig.savefig(out/f'{name}-source-profile-preview.png',dpi=160);plt.close(fig)
    np.savez_compressed(out/'selected-full-source.npz',sourceFaceIds=np.array(list(rows)),sourceObjectIds=np.array([owners[i] for i in rows]),trianglesSvgSourceZ=original)
    print(out)


if __name__=='__main__':main()

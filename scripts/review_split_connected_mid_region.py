"""Raw-height section evidence for the connected Mid declaration; no pack edits."""
import json
import numpy as np
import shapely
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
from matplotlib.collections import LineCollection
from build_split_connected_tower import REV
from declare_split_connected_mid_region import declaration
from authored_region_cells import barycentric
from render_split_remaining_corner_families import sections


def main():
    family=declaration();out=REV/'split-connected-mid-region-proposal-v1';out.mkdir(exist_ok=True)
    (out/'region-declaration.json').write_text(json.dumps(family,indent=2))
    paths=list(family['sourcePacketFiles'])+[str(REV/'split-original-scene-connected-source-review-v1/clove-upward-notch-full-source.npz')]
    wanted=set(family['reviewedSourceFaces']);rows={}
    for path in paths:
        data=np.load(path)
        for face,tri in zip(data['sourceFaceIds'],data['trianglesSvgSourceZ']):
            if int(face) in wanted:rows[int(face)]=tri
    original=np.array(list(rows.values()))
    source=np.array(family['sourceVerticesSvg']);target=np.array(family['targetVerticesSvg']);cells=np.array(family['triangles'])
    polygons=shapely.polygons(source[cells]);tree=shapely.STRtree(polygons);domain=shapely.union_all(polygons)
    def mapped_segments(lines):
        result=[]
        for endpoints in lines:
            line=shapely.LineString(endpoints)
            for i in tree.query(line,predicate='intersects'):
                for piece in shapely.get_parts(shapely.intersection(line,polygons[i])):
                    if not isinstance(piece,shapely.LineString):continue
                    points=shapely.get_coordinates(piece)
                    mapped=barycentric(points,source[cells[i]])@target[cells[i]]
                    result.extend(np.stack((mapped[:-1],mapped[1:]),axis=1))
            for piece in shapely.get_parts(shapely.difference(line,domain)):
                if isinstance(piece,shapely.LineString):
                    points=shapely.get_coordinates(piece);result.extend(np.stack((points[:-1],points[1:]),axis=1))
        return result
    for name,bounds,heights in [('notch',[194,179,244,226],[6.75,8.25,9.75,11.75]),('u-and-balcony',[124,124,210,228],[6.75,9.75,12.75,16.75])]:
        choose=np.all(original[:,:,:2].max(1)>=bounds[:2],axis=1)&np.all(original[:,:,:2].min(1)<=bounds[2:],axis=1)
        mesh=original[choose];fig,axes=plt.subplots(2,2,figsize=(16,13))
        for ax,z in zip(axes.flat,heights):
            lines,_=sections(mesh,z);mapped=mapped_segments(lines)
            ax.add_collection(LineCollection(lines,colors='#dc2626',lw=1,label='Original source'))
            ax.add_collection(LineCollection(mapped,colors='#16a34a',lw=1,label='Connected field proposal'))
            for span in family['reviewedAuthoredSpans']:
                edge=np.array([span['startSvg'],span['endSvg']]);ax.plot(*edge.T,color='#111827',lw=1.3)
            ax.set_xlim(bounds[0],bounds[2]);ax.set_ylim(bounds[3],bounds[1]);ax.set_aspect('equal');ax.grid(alpha=.15);ax.legend(fontsize=8);ax.set_title(f'Original absolute Z {z:g} m')
        fig.suptitle('Connected Mid proposal: original source height sections, no height extrusion.\nBlack: reviewed authored wall spans. Red: source. Green: continuous declared XY mapping. No candidate bake.')
        fig.tight_layout(rect=[0,0,1,.95]);fig.savefig(out/f'{name}-source-height-preview.png',dpi=160);plt.close(fig)
    det=lambda p:(p[:,1,0]-p[:,0,0])*(p[:,2,1]-p[:,0,1])-(p[:,1,1]-p[:,0,1])*(p[:,2,0]-p[:,0,0])
    sd=det(source[cells]);td=det(target[cells]);bad=np.flatnonzero(td/sd< -1e-12)
    (out/'floating-collinearity-review.json').write_text(json.dumps(dict(sourceCells=len(cells),flaggedCells=[dict(cell=int(i),source=source[cells[i]].tolist(),target=target[cells[i]].tolist(),sourceDeterminant=float(sd[i]),targetDeterminant=float(td[i]),ratio=float(td[i]/sd[i])) for i in bad]),indent=2))
    print(out)


if __name__=='__main__':main()

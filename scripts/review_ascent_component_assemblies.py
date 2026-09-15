"""Review complete connected Ascent source assemblies behind contour nominations."""
import gzip,json,math
from collections import defaultdict
from pathlib import Path
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
from mpl_toolkits.mplot3d.art3d import Poly3DCollection
from matplotlib.ticker import MaxNLocator
import numpy as np
from native_compact_wall_profiles import sha
from prepare_ascent_connected_corners import ROOT,REV,OUT


def main():
    folder=REV/'ascent-connected-contour-proposals-v1';objects=defaultdict(list)
    for component in [5,7]:
        data=json.loads(gzip.decompress((folder/f'component-{component}.json.gz').read_bytes()))
        for row in data['spans']:
            for index,plane in enumerate(row['planes']):
                if plane['status']=='plane-proposal':
                    objects[plane['sourceObjectIndex']].append(dict(span=row['completeSpan'],planeIndex=index,sourceFaces=plane['expandedSourceFaces'],seedFaces=plane['seedSourceFaces'],sourcePlane=plane['sourcePlane'],finiteReviewBounds=plane['finiteReviewBoundsSvg']))
    path=ROOT/'supplemented-v2/world/ascent/geometry.npz';raw=np.load(path);points,faces=raw['points'],raw['faces'];meta=json.loads(path.with_suffix('.json').read_text());rows=[];ordered=sorted(objects)
    for page in range(math.ceil(len(ordered)/6)):
        fig=plt.figure(figsize=(18,12))
        for index,obj in enumerate(ordered[page*6:(page+1)*6]):
            ob=meta['objects'][obj];ids=np.arange(ob['firstFace'],ob['firstFace']+ob['faceCount']);xyz=points[faces[ids]];selected=set(fid for record in objects[obj] for fid in record['sourceFaces']);mask=np.isin(ids,list(selected));ax=fig.add_subplot(2,3,index+1,projection='3d')
            ax.add_collection3d(Poly3DCollection(xyz,facecolor='#8ecae6',edgecolor='#28789d',alpha=.14,linewidth=.12));ax.add_collection3d(Poly3DCollection(xyz[mask],facecolor='#e76f51',edgecolor='#a83820',alpha=.25,linewidth=.2))
            lo,hi=xyz.min((0,1)),xyz.max((0,1));ax.set_xlim(lo[0],hi[0]);ax.set_ylim(lo[1],hi[1]);ax.set_zlim(lo[2],hi[2]);ax.set_box_aspect(np.maximum(hi-lo,.15));ax.view_init(elev=25,azim=-52)
            for axis in [ax.xaxis,ax.yaxis,ax.zaxis]:axis.set_major_locator(MaxNLocator(3))
            ax.set_title(f"{obj}: {ob['path'].split('/')[1]}\nSpans {sorted({r['span'] for r in objects[obj]})}",fontsize=10);ax.set_zlabel('Original Z, m',fontsize=8)
            rows.append(dict(sourceObject=obj,sourceObjectPath=ob['path'],sourceFaces=ids.tolist(),sourceBoundsNative=[lo.tolist(),hi.tolist()],nominatedFaces=sorted(selected),contourBindings=objects[obj],page=page+1,reviewStatus='Full source assembly shown for personal role/ownership review. No nomination autoacceptance.'))
        fig.suptitle('Ascent full source assemblies. Blue complete source; orange finite contour nominations.',fontsize=15);fig.tight_layout(rect=[0,0,1,.95]);fig.savefig(OUT/f'assembly-source-page-{page+1}.png',dpi=150,bbox_inches='tight');plt.close(fig)
    report=dict(format='icarus-contour-source-assembly-review-v1',map='ascent',sourceFileSha256=sha(path),sourceGeometrySha256=meta['geometrySha256'],componentSummarySha256=sha(folder/'summary.json'),scriptSha256=sha(Path(__file__)),assemblies=rows,productionMutation=False)
    (OUT/'assembly-source-review.json').write_text(json.dumps(report,indent=2)+'\n');print(json.dumps(dict(assemblies=len(rows),pages=math.ceil(len(rows)/6))))


if __name__=='__main__':main()


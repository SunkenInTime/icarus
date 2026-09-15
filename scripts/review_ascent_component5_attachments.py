"""Group exact retained attachments by source instance for finite transition review."""
import argparse,json
from collections import defaultdict
from pathlib import Path
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
from mpl_toolkits.mplot3d.art3d import Poly3DCollection
import numpy as np
from native_compact_wall_profiles import sha
from prepare_ascent_connected_corners import ROOT,REV,OUT


def main(candidate):
    candidate=Path(candidate);path=candidate/'unchanged-attachment-review.json';review=json.loads(path.read_text());binding=json.loads((candidate/'bindings.json').read_text());families={f['edge']:f for f in binding['families']};control=REV/'global-ground-complete-v2/ascent';c2f=np.load(control/'correspondence.npz')['sourceFaces'];f2o=np.load(REV/'full-height-input-v1/ascent/source-correspondence.npz')['sourceFaces'];c2o=f2o[c2f];rawpath=ROOT/'supplemented-v2/world/ascent/geometry.npz';raw=np.load(rawpath);points,faces=raw['points'],raw['faces'];meta=json.loads(rawpath.with_suffix('.json').read_text());starts=np.array([o['firstFace'] for o in meta['objects']]);affine=np.array(json.loads((ROOT/'tactical-alignment-sides-v1/ascent.json').read_text())['nativeToAttackSvg']);groups=defaultdict(list)
    for row in review['groups']:
        fid=int(c2o[row['retainedControlParent']]);obj=int(np.searchsorted(starts,fid,side='right')-1);groups[(row['family'],obj)].append(dict(row,retainedOriginalSourceFace=fid,movedOriginalSourceFace=int(c2o[row['movedControlParent']])))
    summaries=[]
    for (family,obj),rows in groups.items():
        summaries.append(dict(family=family,completeSpan=families[family].get('completeSpan',families[family].get('completeSpans')),retainedSourceObject=obj,retainedSourcePath=meta['objects'][obj]['path'],maximumMappedGapSvg=max(r['maximumMappedGapSvg'] for r in rows),sharedVertexPairs=sum(r['sharedVertexPairs'] for r in rows),retainedOriginalSourceFaces=sorted({r['retainedOriginalSourceFace'] for r in rows}),movedOriginalSourceFaces=sorted({r['movedOriginalSourceFace'] for r in rows}),records=rows))
    summaries.sort(key=lambda r:-r['maximumMappedGapSvg']);image_paths=[]
    for index,group in enumerate(summaries[:6]):
        ob=meta['objects'][group['retainedSourceObject']];context=points[faces[ob['firstFace']:ob['firstFace']+ob['faceCount']]];retained=points[faces[group['retainedOriginalSourceFaces']]];moved=points[faces[group['movedOriginalSourceFaces']]];fig=plt.figure(figsize=(13,6));top=fig.add_subplot(121);view=fig.add_subplot(122,projection='3d')
        for tris,color,alpha,label in [(context,'#86969d',.04,'Full retained source assembly'),(retained,'#e76f51',.25,'Exact retained attachments'),(moved,'#0077b6',.35,'Moved source faces')]:
            svg=tris[:,:,:2]@affine[:,:2].T+affine[:,2]
            for tri in svg:top.plot(*np.vstack((tri,tri[:1])).T,color=color,alpha=max(alpha,.1),lw=.5)
            view.add_collection3d(Poly3DCollection(tris,facecolor=color,edgecolor=color,alpha=alpha,linewidth=.2))
        for f in binding['families']:
            targets=[f['sharedAuthoredJoins']] if 'sharedAuthoredJoins' in f else [[s['startSvg'],s['endSvg']] for s in f.get('reviewedAuthoredSpans',[])]
            for target in targets:top.plot(*np.array(target).T,color='black',lw=1)
        combined=np.concatenate((retained,moved));svg=combined[:,:,:2]@affine[:,:2].T+affine[:,2];lo=svg.min((0,1))-2;hi=svg.max((0,1))+2;top.set_xlim(lo[0],hi[0]);top.set_ylim(hi[1],lo[1]);top.set_aspect('equal');top.set_title('Exact source: blue moved, orange retained; black SVG')
        lo=combined.min((0,1));hi=combined.max((0,1));pad=np.maximum((hi-lo)*.1,.1);view.set_xlim(lo[0]-pad[0],hi[0]+pad[0]);view.set_ylim(lo[1]-pad[1],hi[1]+pad[1]);view.set_zlim(lo[2]-pad[2],hi[2]+pad[2]);view.set_box_aspect(np.maximum(hi-lo,.2));view.view_init(elev=25,azim=-50);view.set_title('Original source geometry; no assigned transition yet');view.set_zlabel('Original Z, m');fig.suptitle(f"Span {group['completeSpan']}, retained source object {group['retainedSourceObject']}: largest mapped separation {group['maximumMappedGapSvg']:.4f} SVG");fig.tight_layout();image=candidate/f'attachment-source-{index+1}.png';fig.savefig(image,dpi=170);plt.close(fig);group['sourceReviewImage']=str(image);image_paths.append(str(image))
    report=dict(format='icarus-connected-attachment-source-review-v1',map='ascent',component=5,candidatePackSha256=review['candidatePackSha256'],sourceGeometrySha256=meta['geometrySha256'],attachmentReportSha256=sha(path),scriptSha256=sha(Path(__file__)),groups=summaries,scope='Every reported shared-vertex attachment grouped by exact retained source instance and normalized family. Source 3D packets permit semantic review of finite transition ownership; no automatic assignment or acceptance.',productionMutation=False)
    (candidate/'attachment-source-review.json').write_text(json.dumps(report,indent=2)+'\n');print(json.dumps([dict(family=g['family'],object=g['retainedSourceObject'],faces=len(g['retainedOriginalSourceFaces']),gap=g['maximumMappedGapSvg']) for g in summaries[:12]],indent=2))


if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('--candidate',default=str(REV/'ascent-connected-component5-candidate-v1'));main(p.parse_args().candidate)

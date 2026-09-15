"""Add original-source hit and backing-face evidence to frozen review packets."""
import argparse
from collections import Counter
import json
from pathlib import Path
import numpy as np
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
from matplotlib.collections import PolyCollection
from audit_all_map_wall_span_coverage import REV,sha
from build_global_tactical_candidate import GroundField
from review_map_wall_families import CHOICES

def main(name):
    folder=REV/f'{name}-wall-family-review-v1';field_path=REV/f'global-ground-complete-v2/{name}/{name}.tactical-ground.json.gz';field=GroundField(field_path)
    reports=[]
    for sid in CHOICES[name]:
        path=folder/f'span-{sid}.json';packet=json.loads(path.read_text());context=np.load(folder/f'span-{sid}-source-context.npz')
        triangles=context['vertices'];face_ids=context['sourceFaces'];object_ids=context['sourceObjects'];primary=packet['primaryInstanceIndex']
        p=packet['sourcePlane'];center=np.array(p['originXY']);axis=np.array(p['axisXY']);normal=np.array(p['normalXY']);umin,umax=p['alongBoundsMeters']
        records=[];byface={f['face']:np.array(f['vertices']) for f in packet['originalSourceFaces']}
        for row in packet['secondaryContacts']:
            for hit in row['contacts']:
                q=np.array(hit['pointControl']);q[2]+=field.heights(q[None,:2])[0];tri=byface[hit['originalSourceFace']]
                e1,e2=tri[1]-tri[0],tri[2]-tri[0];uv=np.linalg.lstsq(np.column_stack([e1,e2]),q-tri[0],rcond=None)[0]
                projected=tri[0]+uv[0]*e1+uv[1]*e2;error=float(np.linalg.norm(projected-q));bary=[float(1-uv.sum()),*uv.tolist()]
                records.append(dict(**hit,alongSvg=row['alongSvg'],relativeEyeHeightMeters=row['relativeEyeHeightMeters'],
                    pointOriginalSource=q.tolist(),originalFacePlaneErrorMeters=error,originalFaceBarycentric=bary))
        # Backing evidence is deliberately sample-specific. Different instances
        # behind the candidate may own another SVG span and must not be collapsed.
        object_evidence=[]
        for objid in sorted(set(r['sourceObjectIndex'] for r in records)):
            rr=[r for r in records if r['sourceObjectIndex']==objid];z=np.array([r['pointOriginalSource'] for r in rr]);depth=(z[:,:2]-center)@normal
            object_evidence.append(dict(sourceObjectIndex=objid,path=next(o['path'] for o in packet['sourceObjects'] if o['sourceObjectIndex']==objid),
                originalSourceFaceIds=sorted(set(r['originalSourceFace'] for r in rr)),fullPackFaceIds=sorted(set(r['fullPackFace'] for r in rr)),controlFaceIds=sorted(set(r['controlFace'] for r in rr)),
                firstHits=sum(r['depth']==0 for r in rr),secondaryHits=sum(r['depth']>0 for r in rr),
                sourceNormalCoordinatesMeters=[float(depth.min()),float(depth.max())],sourceHitZRangeMeters=[float(z[:,2].min()),float(z[:,2].max())]))
        report=dict(map=name,span=sid,packetSha256=sha(path),groundFieldSha256=sha(field_path),scriptSha256=sha(Path(__file__)),
            contacts=records,instances=object_evidence,
            maximumOriginalFacePlaneErrorMeters=max(r['originalFacePlaneErrorMeters'] for r in records),
            minimumOriginalFaceBarycentric=min(min(r['originalFaceBarycentric']) for r in records),
            scope='Control first and secondary hits lifted through the frozen ground field and verified against their exact original source triangles. No wall ownership or geometry changes inferred.')
        (folder/f'span-{sid}-original-contact-bindings.json').write_text(json.dumps(report,indent=2)+'\n')
        fig,axes=plt.subplots(2,2,figsize=(17,11));fig.suptitle(f'{name.title()} span {sid}: source contacts and separate backing geometry',fontsize=17)
        colors={primary:'#2367c9'};others=sorted((e for e in object_evidence if e['sourceObjectIndex']!=primary),key=lambda e:-e['secondaryHits'])
        palette=['#138856','#bc4b00','#9b45bc','#d09900','#4aabb5','#cf4f80','#787878']
        colors.update({e['sourceObjectIndex']:palette[i%len(palette)] for i,e in enumerate(others)})
        # Every original first/secondary contact retains its object color. Primary
        # source relief is shown in full, not only the nearly coplanar candidate.
        for ax,secondary_only in [(axes[0,0],False),(axes[0,1],True)]:
            for objid in [primary]+[e['sourceObjectIndex'] for e in others]:
                keep=object_ids==objid
                if secondary_only and objid==primary:continue
                tr=triangles[keep];uv=np.stack([(tr[:,:,:2]-center)@axis,tr[:,:,2]],axis=-1)
                ax.add_collection(PolyCollection(uv,facecolors=colors[objid],edgecolors=colors[objid],linewidths=.2,alpha=.14 if objid==primary else .1))
                rr=[r for r in records if r['sourceObjectIndex']==objid and (r['depth']>0 if secondary_only else r['depth']==0)]
                if rr:
                    q=np.array([r['pointOriginalSource'] for r in rr]);ax.scatter((q[:,:2]-center)@axis,q[:,2],s=9,color=colors[objid],label=str(objid))
            ax.autoscale_view();ax.set(xlim=(umin-.4,umax+.4),xlabel='Along source wall (m)',ylabel='Original world Z (m)',title='Secondary contacts and backing instances' if secondary_only else 'Original first-contact elevation; all primary relief shown')
            ax.legend(fontsize=8,ncol=2)
        for objid in [primary]+[e['sourceObjectIndex'] for e in others]:
            rr=[r for r in records if r['sourceObjectIndex']==objid and r['relativeEyeHeightMeters']==1.75]
            if not rr:continue
            q=np.array([r['pointOriginalSource'] for r in rr]);axes[1,0].scatter((q[:,:2]-center)@axis,(q[:,:2]-center)@normal,s=12,color=colors[objid],label=str(objid))
        axes[1,0].axhline(0,color='black',lw=.5);axes[1,0].set(xlabel='Along source wall (m)',ylabel='Across-wall source offset (m)',title='Standing primary and secondary contacts remain separate');axes[1,0].legend(fontsize=8,ncol=2)
        axes[1,1].axis('off');lines=[f'Primary instance {primary}: '+packet['primaryInstance']['path'].split('/')[-2],
            f'Exact triangle lifting error: {report["maximumOriginalFacePlaneErrorMeters"]:.2g} m','Other instances, first / secondary sampled contacts:']
        lines += [f'{e["sourceObjectIndex"]}: {e["firstHits"]} / {e["secondaryHits"]}   '+e['path'].split('/')[-2] for e in others]
        axes[1,1].text(0,1,'\n'.join(lines),va='top',fontsize=10,linespacing=1.7)
        fig.tight_layout(rect=(0,0,1,.96));fig.savefig(folder/f'span-{sid}-backing-review.png',dpi=150);plt.close(fig)
        reports.append({k:report[k] for k in ('map','span','maximumOriginalFacePlaneErrorMeters','minimumOriginalFaceBarycentric','instances')})
    (folder/'original-contact-summary.json').write_text(json.dumps(reports,indent=2)+'\n')
    print(name,[(r['span'],r['maximumOriginalFacePlaneErrorMeters'],r['minimumOriginalFaceBarycentric']) for r in reports],flush=True)

if __name__=='__main__':
    parser=argparse.ArgumentParser();parser.add_argument('map',choices=CHOICES);main(parser.parse_args().map)

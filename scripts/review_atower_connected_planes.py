"""Source-only tower plane inventory for connected authored span proposals."""
import json,gzip,hashlib
from pathlib import Path
import numpy as np
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
from mpl_toolkits.mplot3d.art3d import Poly3DCollection
from render_competing_floor_assemblies import clip_mesh_xy

ROOT=Path('E:/IcarusWorldAudit/2026-09-06');REV=ROOT/'tactical-visibility-revision'

def main():
    out=REV/'split-multiplane-corner-proposals-v1'
    coverage=json.loads(gzip.decompress((REV/'all-map-wall-span-coverage-v1/split/attack.coverage.json.gz').read_bytes()))
    raw=np.load(ROOT/'supplemented-v2/world/split/geometry.npz');p,f=raw['points'],raw['faces'];meta=json.loads((ROOT/'supplemented-v2/world/split/geometry.json').read_text())
    affine=np.array(json.loads((ROOT/'tactical-alignment-sides-v1/split.json').read_text())['nativeToAttackSvg'])
    records=[]
    for edge in range(87,99):
        span=next(s for s in coverage['spans'] if s['legacyStraightEdgeIndex']==edge)
        rows=[coverage['samples'][i] for i in span['sampleRows'] if coverage['samples'][i].get('relativeEyeHeightMeters')==1.75 and coverage['samples'][i]['status']=='contact']
        seeds=sorted({r['originalSourceFace'] for r in rows});objects=sorted({r['sourceObjectIndex'] for r in rows})
        target=np.array([span['startSvg'],span['endSvg']]);tangent=target[1]-target[0];tangent/=np.linalg.norm(tangent)
        planes=[]
        for seed in seeds:
            xyz=p[f[seed]];normal=np.cross(xyz[1]-xyz[0],xyz[2]-xyz[0]);normal/=np.linalg.norm(normal)
            if abs(normal[2])>.02:continue
            xy=xyz[:,:2]@affine[:,:2].T+affine[:,2];_,_,basis=np.linalg.svd(xy-xy.mean(0));st=basis[0]
            if st@tangent<0:st=-st
            sn=np.array([-st[1],st[0]]);offset=xy.mean(0)@sn
            if abs(st@tangent)<np.cos(np.deg2rad(10)):continue
            if any(abs(sn@q['normal'])>.99999 and abs(offset-q['offset'])<.005 for q in planes):continue
            planes.append(dict(tangent=st,normal=sn,offset=float(offset),seed=seed))
        lo=target.min(0)-3;hi=target.max(0)+3
        groups=[]
        for plane in planes:
            selected=[];triangles=[]
            for obj in objects:
                entry=meta['objects'][obj];ids=np.arange(entry['firstFace'],entry['firstFace']+entry['faceCount']);xyz=p[f[ids]].copy();xyz[:,:,:2]=xyz[:,:,:2]@affine[:,:2].T+affine[:,2]
                residual=np.max(abs(xyz[:,:,:2]@plane['normal']-plane['offset']),axis=1)
                candidate=ids[residual<.005]
                for fid in candidate:
                    tri=p[f[fid]].copy();tri[:,:2]=tri[:,:2]@affine[:,:2].T+affine[:,2]
                    clipped=clip_mesh_xy(np.array([tri]),lo,hi)
                    if len(clipped):selected.append(int(fid));triangles.extend(clipped)
            groups.append(dict(seed=plane['seed'],tangent=plane['tangent'].tolist(),normal=plane['normal'].tolist(),offset=plane['offset'],sourceFaces=selected,clippedTrianglesSvgZ=np.array(triangles).tolist()))
        records.append(dict(edge=edge,completeSpan=span['span'],subpath=span['subpath'],targetSvg=target.tolist(),sourceObjects=[dict(index=o,**meta['objects'][o]) for o in objects],standingContacts=len(rows),standingSamples=len(span['samplePositions']),standingSeedFaces=seeds,sourcePlanes=groups,clipBoundsSvg=[*lo,*hi],status='Exact plane proposal, not accepted ownership. Relief and shared corner profiles require joint partition.'))
    for start in range(0,len(records),3):
        fig=plt.figure(figsize=(17,13))
        for row,record in enumerate(records[start:start+3]):
            target=np.array(record['targetSvg']);lo=np.array(record['clipBoundsSvg'][:2]);hi=np.array(record['clipBoundsSvg'][2:]);ax=fig.add_subplot(3,2,row*2+1);plan=fig.add_subplot(3,2,row*2+2)
            alltri=[]
            for i,group in enumerate(record['sourcePlanes']):
                tris=np.array(group['clippedTrianglesSvgZ']);color=plt.cm.tab10(i)
                if not len(tris):continue
                alltri.extend(tris)
                for tri in tris:
                    along=(tri[:,:2]-target[0])@np.array(group['tangent']);ax.fill(along,tri[:,2],color=color,alpha=.35);ax.plot(np.r_[along,along[0]],np.r_[tri[:,2],tri[0,2]],color=color,linewidth=.5)
                for tri in tris:plan.plot(*np.vstack([tri,tri[0]])[:,:2].T,color=color,linewidth=.35,alpha=.6)
            if alltri:
                ax.set_xlabel('Along original source plane, SVG units');ax.set_ylabel('Original source Z, m');ax.grid(alpha=.2)
            for s in coverage['spans']:
                line=np.array([s['startSvg'],s['endSvg']])
                if s['subpath']==3 and np.all(line.max(0)>=lo) and np.all(line.min(0)<=hi):plan.plot(*line.T,color='#ea580c',linewidth=2);plan.text(*line.mean(0),str(s['legacyStraightEdgeIndex']) if s['legacyStraightEdgeIndex'] is not None else 'span'+str(s['span']),fontsize=8,clip_on=True)
            plan.set_xlim(lo[0],hi[0]);plan.set_ylim(hi[1],lo[1]);plan.set_aspect('equal');plan.grid(alpha=.2)
            ax.set_title(f"Edge{record['edge']}, {sum(len(g['sourceFaces']) for g in record['sourcePlanes'])} plane faces, {record['standingContacts']}/{record['standingSamples']} standing contacts",fontsize=11)
            plan.set_title('Original source plane fragments and authored contour',fontsize=11)
        fig.suptitle('Connected Split tower proposal. Height gaps describe selected source planes only; other geometry may block. No candidate bake.');fig.tight_layout(rect=[0,0,1,.97]);fig.savefig(out/f'atower-connected-planes-{start//3+1}.png',dpi=150);plt.close(fig)
    report=dict(sourceGeometrySha256=meta['geometrySha256'],generatorSha256=hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),planes=records,scope='Spatial and plane-normal grouping only. Exact raw source IDs retained. Multiple planes are separate. Bounds preserve outside fragments in a future bake. Neighboring ownership and closure still need proof.')
    (out/'atower-connected-plane-proposals.json').write_text(json.dumps(report,indent=2));print([(r['edge'],[len(g['sourceFaces']) for g in r['sourcePlanes']]) for r in records])

if __name__=='__main__':main()

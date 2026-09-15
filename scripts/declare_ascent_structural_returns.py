"""Finite, review-only Ascent return declarations with original height fragments."""
import gzip
import json
from pathlib import Path
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
import numpy as np
from declare_ascent_connected_corners import clip_along
from native_compact_wall_profiles import sha
from prepare_ascent_connected_corners import ROOT, REV, OUT, frame


def main():
    folder = REV/'ascent-connected-contour-proposals-v1'
    components = [json.loads(gzip.decompress((folder/f'component-{c}.json.gz').read_bytes())) for c in [5, 7]]
    rows = {r['completeSpan']: r for c in components for r in c['spans']}
    raw_path = ROOT/'supplemented-v2/world/ascent/geometry.npz'
    raw = np.load(raw_path)
    meta = json.loads(raw_path.with_suffix('.json').read_text())
    affine = np.array(json.loads((ROOT/'tactical-alignment-sides-v1/ascent.json').read_text())['nativeToAttackSvg'])
    def source_triangles(ids):
        xyz = raw['points'][raw['faces'][ids]].copy()
        xyz[:, :, :2] = xyz[:, :, :2] @ affine[:, :2].T + affine[:, 2]
        return xyz
    def plane(span, index):
        g = rows[span]['planes'][index]
        return dict(normal=g['sourcePlane']['normal'], offset=g['sourcePlane']['offset'], sourceObject=g['sourceObjectIndex'], sourceFaces=g['expandedSourceFaces'], planeProposal=[span,index])
    def raw_plane(fid):
        tri = source_triangles([fid])[0]
        n = np.cross(tri[1]-tri[0], tri[2]-tri[0]); n /= np.linalg.norm(n[:2])
        return dict(normal=n[:2].tolist(), offset=float(np.mean(tri[:, :2]@n[:2])), sourceObject=667, sourceFaces=[fid], derivation='Exact opposite body face of the reviewed column; same-instance source geometry, not an unrelated first-hit plane.')
    selections = [
        (138, 667, [0,1], plane(137,12), raw_plane(167037)),
        (148, 8034, [0], plane(147,4), plane(149,0)),
        (184, 6871, [0], plane(183,1), plane(185,0)),
        (191, 8034, [0], plane(190,0), plane(192,2)),
        (194, 4422, [1,2], plane(193,3), plane(195,0)),
        (199, 7529, [0], plane(198,2), plane(200,0)),
    ]
    declarations = []
    for span,obj,indices,left,right in selections:
        selected = sorted({fid for i in indices for fid in rows[span]['planes'][i]['expandedSourceFaces']})
        assert all(rows[span]['planes'][i]['sourceObjectIndex']==obj for i in indices)
        primary = plane(span,indices[0])
        joins = []
        for endpoint,neighbor in enumerate([left,right]):
            source = np.linalg.solve(np.array([primary['normal'],neighbor['normal']]), [primary['offset'],neighbor['offset']])
            joins.append(dict(key=f"ascent-source-{obj}-span-{span}-end-{endpoint}",sourceSvg=source.tolist(),targetSvg=rows[span]['authoredEndpoints'][endpoint],incidentSpan=span-1 if endpoint==0 else span+1,sourceObject=obj,neighborSourcePlane=neighbor,rule='All reviewed incident fragments of this source assembly must reuse this exact join. Other backing assemblies retain separate source profiles until their finite ownership is resolved.'))
        sf,length = frame(joins[0]['sourceSvg'],joins[1]['sourceSvg'])
        tf,target_length = frame(*rows[span]['authoredEndpoints'])
        origin,tangent = np.array(sf['origin']),np.array(sf['tangent'])
        triangles = source_triangles(selected)
        fragments, outside = [], []
        for fid,triangle in zip(selected,triangles):
            clipped = clip_along(triangle,0,length,origin,tangent)
            along = (triangle[:,:2]-origin)@tangent
            if len(clipped)>=3:
                fragments.append(dict(sourceFace=fid,sourceBarycentrics=clipped[:,2:].tolist(),sourceAlongZ=clipped[:,:2].tolist(),targetAlongZ=np.column_stack((clipped[:,0]/length*target_length,clipped[:,1])).tolist()))
            if along.min()<0 or along.max()>length:
                outside.append(dict(sourceFace=fid,sourceAlongBounds=[float(along.min()),float(along.max())],decision='Preserve exact outside fragment unchanged; no source cap is discarded by endpoint clamping.'))
        ob = meta['objects'][obj]
        ids = np.arange(ob['firstFace'],ob['firstFace']+ob['faceCount'])
        other = source_triangles(ids)
        unresolved = []
        for endpoint,j in enumerate(joins):
            p = np.array(j['sourceSvg'])
            near = np.all(other[:,:,:2].max(1)>=p-.3,axis=1)&np.all(other[:,:,:2].min(1)<=p+.3,axis=1)
            for fid,tri in zip(ids[near],other[near]):
                if int(fid) not in selected:
                    unresolved.append(dict(sourceFace=int(fid),nearJoin=endpoint,sourceSvgZ=tri.tolist(),decision='Exact same-instance cap/relief candidate; retain source until face ownership is assigned to an incident family.'))
        declaration = dict(completeSpan=span,legacyStraightEdgeIndex=rows[span]['legacyStraightEdgeIndex'],sourceObject=obj,sourceObjectPath=ob['path'],sourceFrame=sf,targetFrame=tf,sourceAlong=[0,length],targetAlong=[0,target_length],reviewedSourceFaces=selected,originalHeightFragments=fragments,joins=joins,outsideSourceFragments=outside,unassignedAttachedFacets=unresolved,status='structural-source-proposal; finite face ownership and connected join coverage still require review',heightPolicy='Original source Z at exact barycentric coordinates. Preserve gaps and every material/UV/state reference; no solid extrusion.',bakeAllowed=False)
        declarations.append(declaration)
    fig,axes = plt.subplots(2,3,figsize=(15,9))
    for ax,d in zip(axes.flat,declarations):
        for f in d['originalHeightFragments']:
            q=np.array(f['targetAlongZ']);ax.fill(q[:,0],q[:,1],color='#0077b6',alpha=.22);ax.plot(*np.vstack((q,q[:1])).T,lw=.5,color='#005f73')
        ax.set_title(f"Return {d['completeSpan']}, object {d['sourceObject']}\n{len(d['reviewedSourceFaces'])} exact source faces")
        ax.set_xlabel('Authored along, SVG');ax.set_ylabel('Original Z, m');ax.grid(alpha=.2)
    fig.suptitle('Finite Ascent structural return profiles. No filled height envelope or candidate bake.')
    fig.tight_layout(rect=[0,0,1,.95]);fig.savefig(OUT/'six-return-height-profiles.png',dpi=180);plt.close(fig)
    report=dict(format='icarus-reviewed-finite-return-proposals-v1',map='ascent',sourceFileSha256=sha(raw_path),sourceGeometrySha256=meta['geometrySha256'],componentSummarySha256=sha(folder/'summary.json'),scriptSha256=sha(Path(__file__)),declarations=declarations,productionMutation=False)
    (OUT/'structural-return-declarations.json').write_text(json.dumps(report,indent=2)+'\n')
    print(json.dumps([dict(span=d['completeSpan'],faces=len(d['reviewedSourceFaces']),outside=len(d['outsideSourceFragments']),attachedCandidates=len(d['unassignedAttachedFacets']),sourceJoins=[j['sourceSvg'] for j in d['joins']]) for d in declarations],indent=2))


if __name__=='__main__':main()

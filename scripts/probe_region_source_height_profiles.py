"""Independent original-face height sections mapped through declared XY cells.

Uses no generated candidate triangles. Contact uncertainty is reported rather
than changing a source profile or treating every authored outline as opaque.
"""
import argparse,json
from pathlib import Path
import numpy as np
import shapely
from tactical_alignment_audit import pack
from native_compact_wall_profiles import sha
from prepare_ascent_connected_corners import ROOT,REV


def run(folder,dump_sections=False):
    folder=Path(folder);binding=json.loads((folder/'bindings.json').read_text());family=binding['families'][0]
    source_path=Path(binding['sourceBackup']);_,arrays=pack(source_path);ids=np.asarray(family['controlFaces'],dtype=int)
    xyz=arrays['vertices'][arrays['faces'][ids]];aff=np.asarray(json.loads((ROOT/'tactical-alignment-sides-v1/ascent.json').read_text())['nativeToAttackSvg'])
    xyz[:,:,:2]=xyz[:,:,:2]@aff[:,:2].T+aff[:,2]
    c2f=np.load(REV/'global-ground-complete-v2/ascent/correspondence.npz')['sourceFaces'];f2o=np.load(REV/'full-height-input-v1/ascent/source-correspondence.npz')['sourceFaces'];original=f2o[c2f[ids]]
    assert np.all(np.isin(original,family['reviewedSourceFaceIds']))
    source=np.asarray(family['sourceVerticesSvg']);target=np.asarray(family['targetVerticesSvg']);cells=np.asarray(family['triangles']);sp=source[cells];tp=target[cells];polys=shapely.polygons(sp);tree=shapely.STRtree(polys)
    queries=json.loads((folder/'independent-junction-rays.json').read_text())['records'];rows=[];statistics=[]
    for z in sorted({q['relativeEyeHeightMeters'] for q in queries}):
        segments=[];parents=[];cellids=[];coplanar=[];masked=[]
        for triangle,cid,oid in zip(xyz,ids,original):
            heights=triangle[:,2]-z
            if heights.min()>0 or heights.max()<0:continue
            if np.all(heights==0):coplanar.append(int(oid));continue
            cuts=[triangle[i,:2] for i in np.flatnonzero(heights==0)]
            for i,j in [(0,1),(1,2),(2,0)]:
                if heights[i]*heights[j]<0:cuts.append(triangle[i,:2]+(triangle[j,:2]-triangle[i,:2])*heights[i]/(heights[i]-heights[j]))
            if not cuts:continue
            if arrays['faceMasks'][cid]>=0:masked.append(int(oid));continue
            a,b=cuts[0],cuts[-1];line=shapely.Point(a) if np.array_equal(a,b) else shapely.LineString([a,b])
            for cell in tree.query(line):
                piece=line.intersection(polys[cell])
                if piece.is_empty:continue
                if piece.geom_type not in ['LineString','Point']:raise ValueError(piece.geom_type)
                coords=np.asarray(piece.coords);uv=np.linalg.solve((sp[cell,1:]-sp[cell,0]).T,(coords-sp[cell,0]).T).T;mapped=tp[cell,0]+uv@(tp[cell,1:]-tp[cell,0])
                segments.append([mapped[0],mapped[-1]]);parents.append(int(oid));cellids.append(int(cell))
        seg=np.asarray(segments);statistics.append(dict(height=z,sections=len(seg),coplanarSourceFaces=coplanar,maskedSourceFaces=masked))
        if dump_sections:np.savez_compressed(folder/f'original-source-sections-height-{z:g}.npz',segments=seg,originalSourceFaces=parents,regionCells=cellids)
        for q in queries:
            if q['relativeEyeHeightMeters']!=z:continue
            p=np.asarray(q['expectedContactSvg']);d=seg[:,1]-seg[:,0];length=(d*d).sum(1);u=np.zeros(len(seg));np.divide(((p-seg[:,0])*d).sum(1),length,out=u,where=length>0);nearest=seg[:,0]+np.clip(u,0,1)[:,None]*d;dist=np.linalg.norm(nearest-p,axis=1);order=np.argsort(dist)[:3];minimum=float(dist[order[0]])
            status='uncertain-contact-band' if minimum<=1e-7 else 'source-profile-gap'
            if coplanar or masked:status='unresolved-source-profile-scope'
            rows.append(dict(query=q,classification=status,nearestDeclaredSourceSectionDistanceSvg=minimum,nearestSections=[dict(originalSourceFace=parents[i],regionCell=cellids[i],endpointsSvg=seg[i].tolist(),distanceSvg=float(dist[i])) for i in order]))
    report=dict(format='icarus-original-source-height-profile-review-v1',sourcePackSha256=sha(source_path),bindingsSha256=sha(folder/'bindings.json'),scriptSha256=sha(Path(__file__)),heights=statistics,rows=rows,scope='Original reviewed opaque source face horizontal sections, clipped to declared source cells and mapped directly to authored coordinates. No generated candidate triangles used. Distances <=1e-7 SVG remain numerical contact uncertainty; masked/coplanar heights are not certified.',productionMutation=False)
    name='original-source-height-profile-section-dump.json' if dump_sections else 'original-source-height-profile-review.json'
    (folder/name).write_text(json.dumps(report,indent=2)+'\n')
    for state in ['passed-authored-wall','no-candidate-hit','exact-contact']:
        selected=[r for r in rows if r['query']['status']==state];print(state,len(selected),{c:sum(r['classification']==c for r in selected) for c in {r['classification'] for r in selected}},flush=True)

if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('candidate');p.add_argument('--dump-sections',action='store_true');a=p.parse_args();run(a.candidate,dump_sections=a.dump_sections)

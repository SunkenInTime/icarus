"""Compile the reviewed tower contour as shared joins and exact source profiles.

This remains a candidate. Shared joins are declared once, so adjacent families
cannot independently choose different authored endpoint coordinates.
"""
import argparse,copy,gzip,hashlib,json
from pathlib import Path
import numpy as np
from build_split_normalized_wall_families import main as bake

ROOT=Path('E:/IcarusWorldAudit/2026-09-06');REV=ROOT/'tactical-visibility-revision'

def frame(a,b):
    a,b=np.array(a),np.array(b);t=b-a;length=float(np.linalg.norm(t));t/=length
    return dict(origin=a.tolist(),tangent=t.tolist(),normal=[-float(t[1]),float(t[0])]),length

def declarations():
    directory=REV/'split-multiplane-corner-proposals-v1'
    profiles=json.loads((directory/'atower-connected-plane-proposals.json').read_text());planes={r['edge']:r for r in profiles['planes']}
    corner=json.loads((directory/'atower-connected-profile-proposal.json').read_text())
    diagonal=json.loads((REV/'diagonal-wall-source-review-v1/split-84.json').read_text())
    raw=np.load(ROOT/'supplemented-v2/world/split/geometry.npz');points,faces=raw['points'],raw['faces'];meta=json.loads((ROOT/'supplemented-v2/world/split/geometry.json').read_text());starts=np.array([o['firstFace'] for o in meta['objects']])
    affine=np.array(json.loads((ROOT/'tactical-alignment-sides-v1/split.json').read_text())['nativeToAttackSvg'])
    coverage=json.loads(gzip.decompress((REV/'all-map-wall-span-coverage-v1/split/attack.coverage.json.gz').read_bytes()))
    ordered=[84,85,86,87,88,89,90,91,92,93,94,95,96,10099,97,98]
    # Each pair is the source join before this span. The final span returns to
    # the first join. These are structural inner joins, not outer trim extrema.
    source_joins=[
        [337.936768073448,157.726739875244],
        [324.2514863932356,183.139241841751],
        [324.2514863932356,185.08998],
        [332.066995,185.08998],
        [332.06754,200.73253],
        [326.20264,212.46148],
        [326.20257,232.00954],
        [357.47953,232.0095],
        [357.47953,214.416204],
        [373.118011,214.416204],
        [373.118011,198.777723],
        [349.663798,198.777723],
        [349.663794,161.63639],
        [344.075855,149.934822],
        [341.8448820337362,149.907499],
        [341.8448820337362,157.726710047],
    ]
    source_joins=np.array(source_joins)
    # Recover exact shared raw XY where the displayed rounded review values
    # were printed for humans. The nearest vertex must be extremely close;
    # this only removes report rounding, never selects another structural join.
    all_source_ids=set(diagonal['primaryPlaneSourceFaces'])
    for row in planes.values():
        for group in row['sourcePlanes']:all_source_ids.update(group['sourceFaces'])
    for row in corner['families']:all_source_ids.update(row['sourceFaces'])
    all_xy=points[faces[list(all_source_ids)]][:,:,:2].reshape(-1,2)@affine[:,:2].T+affine[:,2]
    for i,join in enumerate(source_joins):
        d=np.linalg.norm(all_xy-join,axis=1);nearest=int(d.argmin())
        if d[nearest]<.00002:source_joins[i]=all_xy[nearest]
    families=[];join_rows=[]
    caps85=[1896459,1896460,1896461,1896462,1896414,1896403,1896404,1896419,1896420]
    caps86=[1896425,1896426,1896427,1896428,1896431,1896432,1896435,1896436,1896448,1896449]
    for i,edge in enumerate(ordered):
        span=next(s for s in coverage['spans'] if s['span']==99) if edge==10099 else next(s for s in coverage['spans'] if s['legacyStraightEdgeIndex']==edge)
        target=np.array([span['startSvg'],span['endSvg']]);source=np.array([source_joins[i],source_joins[(i+1)%len(ordered)]])
        sf,sl=frame(*source);tf,tl=frame(*target)
        if edge==84:ids=diagonal['primaryPlaneSourceFaces'];bounds=None
        elif edge in [85,86]:
            prior=next(r for r in corner['families'] if r['edge']==edge);ids=prior['sourceFaces']+(caps85 if edge==85 else caps86);bounds=copy.deepcopy(prior['box'])
            if edge==85:bounds[3]=185.482 # Reviewed high roof/side cap extent.
        elif edge==10099:
            ids=[1880031,1880032,1880045,1880046,1893774,1893775];bounds=[341.68,149.88,344.116,149.95]
        else:
            row=planes[edge]
            # The secondary90 contact plane is a separate ledge beyond the
            # 90/91 join. Its sampled endpoint hit does not assign that object
            # to the main90 wall. Keep the whole ledge and its opening intact.
            groups=row['sourcePlanes'][:1] if edge==90 else row['sourcePlanes']
            ids=[fid for group in groups for fid in group['sourceFaces']];bounds=copy.deepcopy(row['clipBoundsSvg'])
        ids=sorted(set(ids));xyz=points[faces[ids]].copy();xyz[:,:,:2]=xyz[:,:,:2]@affine[:,:2].T+affine[:,2]
        if bounds is None:bounds=[*(xyz[:,:,:2].min((0,1))-1e-6),*(xyz[:,:,:2].max((0,1))+1e-6)]
        objects=sorted(set((np.searchsorted(starts,ids,side='right')-1).tolist()))
        families.append(dict(edge=edge,completeSpan=span['span'],legacyStraightEdgeIndex=span['legacyStraightEdgeIndex'],sourceFrame=sf,targetFrame=tf,sourceAlong=[0.,sl],targetAlong=[0.,tl],box=np.array(bounds).tolist(),objects=objects,reviewedSourceFaces=ids,sharedSourceJoins=source.tolist(),sharedAuthoredJoins=target.tolist(),role='Reviewed connected tower wall profile; original Z/UV and all separated height sheets retained.',unresolved='Prototype requires source-junction closure and adjacent relief ownership checks.'))
        join_rows.append(dict(beforeEdge=edge,sourceSvg=source[0].tolist(),targetSvg=target[0].tolist(),provenance='Original structural plane intersection or shared raw source vertex, reviewed source packet.'))
    for i,family in enumerate(families):
        next_family=families[(i+1)%len(families)]
        if np.linalg.norm(np.array(family['sharedAuthoredJoins'][1])-next_family['sharedAuthoredJoins'][0])>1e-9:raise ValueError('Authored contour is not connected')
    return families,dict(format='icarus-reviewed-connected-contour-v1',sourceGeometrySha256=meta['geometrySha256'],orderedFamilyEdges=ordered,joins=join_rows,families=families,reviewPackets=['atower-connected-profile-proposal.json','atower-cap-categories.json','atower-connected-plane-proposals.json'],sourceCornerEnvelope=dict(edge84StartRawFace=1894086,edge84EndRawFace=1894092,reason='Source endpoint Y varies with height. The inner measured profile envelope makes every original corner endpoint clamp to the same authored join, with unchanged Z and explicit barycentric partitions.'),excludedAdjacentPlane=dict(edge=90,planeSeed=1892878,reason='Separate low ledge beyond the90/91 inner join. V14 incorrectly collapsed a portion; V15 keeps all original fragments.'),smallReturn=dict(completeSpan=99,syntheticFamilyKey=10099,legacyStraightEdgeIndex=None,reason='Real authored straight return omitted by legacy index. Its source profile is explicit, not inferred closure.'),status='Prototype declarations; closure and source partition verification required.')

if __name__=='__main__':
    parser=argparse.ArgumentParser();parser.add_argument('--version',default='v14');parser.add_argument('--declarations-only',action='store_true');args=parser.parse_args()
    families,proof=declarations();target=REV/f'split-tower-connected-declarations-{args.version}.json';proof['generatorSha256']=hashlib.sha256(Path(__file__).read_bytes()).hexdigest();target.write_text(json.dumps(proof,indent=2));print(target,flush=True)
    if not args.declarations_only:bake(out=REV/f'split-wall-family-normalized-candidate-{args.version}',extra_families=families)

"""Source-nav origins and frozen rays around the older105 clip frontier."""
import gzip
import hashlib
import json
from pathlib import Path

import numpy as np

from native_reference_cast import NativeReferenceModel
from tactical_alignment_composite import explicit_warp

ROOT=Path('E:/IcarusWorldAudit/2026-09-06')
REV=ROOT/'tactical-visibility-revision'


def main():
    out=REV/'split-legacy105-frontier-review-v1'
    out.mkdir(exist_ok=True)
    path=out/'source-nav-rays.json'
    if path.exists():raise FileExistsError(path)
    nav_path=Path('assets/maps/world/split_navigation.json.gz')
    nav=json.loads(gzip.decompress(nav_path.read_bytes()))
    assert 'sourcePolygonIds' not in nav, 'Use original UV navigation, not warped child data'
    ui=json.loads(Path('assets/maps/world/height_catalog.json').read_text())['maps']['split']['uiTransform']
    field=nav['floorMesh'];vertices=np.array(field['vertices']).reshape(-1,3);indices=np.array(field['triangles']).reshape(-1,4)
    centers=vertices[indices[:,1:]].mean(1);uv=centers[:,:2]/field['coordinateScale']
    native=np.column_stack(((uv[:,1]-ui['YScalarToAdd'])/(100*ui['YMultiplier']),-(uv[:,0]-ui['XScalarToAdd'])/(100*ui['XMultiplier'])))
    wp=REV/'display-warps-v1/split.display-warp.json.gz';w=json.loads(gzip.decompress(wp.read_bytes()))
    matrix=np.column_stack((w['projection']['axisU'],w['projection']['axisV']));origin=np.asarray(w['projection']['origin']);inverse=np.linalg.inv(matrix)
    source=np.array(w['sourceNativeMeters']).reshape(-1,2)@matrix.T+origin;target=np.array(w['targetAttackSvg']).reshape(-1,2);cells=np.array(w['triangles']).reshape(-1,3)
    forward=explicit_warp(source,target-source,cells);backward=explicit_warp(target,source-target,cells)
    display=forward.apply(native@matrix.T+origin)
    folder=REV/'split-wall-family-normalized-candidate-v29'
    paths={'sourceControl':REV/'global-ground-complete-v2/split/split.height.bin.gz','v29':folder/'split.height.bin.gz','originalHeight':REV/'full-height-input-v1/split/split.height.bin.gz'}
    models={k:NativeReferenceModel(p,REV/'native-tactical-rays-build/Release/tactical_reference_cast.dll') for k,p in paths.items()}
    control=np.load(REV/'global-ground-complete-v2/split/correspondence.npz')['sourceFaces'];full=np.load(REV/'full-height-input-v1/split/source-correspondence.npz')['sourceFaces'];parents=np.load(folder/'correspondence.npz')['sourceFaces']
    meta=json.loads((ROOT/'supplemented-v2/world/split/geometry.json').read_text());starts=np.array([o['firstFace'] for o in meta['objects']])
    def cast(name,start,end):
        hit=models[name].cast(start,end,end_padding=0,end_inclusive=True)
        if hit is None:return None
        raw=int(full[hit['face']] if name=='originalHeight' else full[control[parents[hit['face']] if name=='v29' else hit['face']]])
        obj=int(np.searchsorted(starts,raw,side='right')-1)
        hit.update(rawSourceFace=raw,sourceObject=obj,sourcePath=meta['objects'][obj]['path'],displayedHitSvg=forward.apply(np.array(hit['point'][:2])@matrix.T+origin).tolist())
        return hit
    targets=[[float(x),280.95] for x in np.linspace(279.2,292.2,27)]
    targets += [[292.6,float(y)] for y in np.linspace(281.4,310.7,21)]
    targets += [[285.,float(y)] for y in [282.,286.,294.,302.,308.,312.]]
    target_native=(backward.apply(np.array(targets))-origin)@inverse.T
    fixtures=[]
    for n,wanted in enumerate([[288.,285.],[287.,300.],[289.,309.],[299.,316.]]):
        eligible=np.array(nav['walkable'])[indices[:,0]].astype(bool)
        distance=np.linalg.norm(display-wanted,axis=1);distance[~eligible]=np.inf;index=int(distance.argmin())
        xy=native[index];ground=centers[index,2]/100
        rows=[]
        for point,raw_target in zip(targets,target_native):
            entry=dict(targetSvg=point)
            for z in [1.75,2.75,8.25]:
                start=np.r_[xy,z];end=np.r_[raw_target,z]
                entry[f'relativeEye{z:g}']={k:cast(k,start,end) for k in ['sourceControl','v29']}
            entry['originalStanding']=cast('originalHeight',np.r_[xy,ground+1.75],np.r_[raw_target,ground+1.75])
            rows.append(entry)
        fixtures.append(dict(id=f'legacy105-nav-{n}',sourceNavFloorTriangle=index,sourceNavParent=int(indices[index,0]),
            nativeOrigin=xy.tolist(),displayedOriginSvg=display[index].tolist(),sourceFloorMeters=float(ground),
            originSelectionDistanceSvg=float(distance[index]),records=rows))
    report=dict(scope=__doc__,sourceNavigationSha256=hashlib.sha256(nav_path.read_bytes()).hexdigest(),
        displayWarpSha256=hashlib.sha256(wp.read_bytes()).hexdigest(),packs={k:hashlib.sha256(p.read_bytes()).hexdigest() for k,p in paths.items()},
        scriptSha256=hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),fixtures=fixtures,
        limitations='Original nav floor centers are source-backed standing origins. Relative-height casts match the provisional runtime; only originalStanding casts use source-absolute standing Z. No candidate absolute-height oracle is inferred.')
    path.write_text(json.dumps(report,indent=2))
    for f in fixtures:
        print(f['id'],f['displayedOriginSvg'],f['sourceFloorMeters'],flush=True)
        for z in [1.75,2.75,8.25]:
            rows=[r[f'relativeEye{z:g}'] for r in f['records']]
            changes=sum((r['sourceControl'] is None)!=(r['v29'] is None) for r in rows)
            print(z,'blocked/clear changes',changes,flush=True)


if __name__=='__main__':main()

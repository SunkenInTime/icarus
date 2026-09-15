"""Check proposal source bindings and two real Split coverage regressions."""
import argparse,json,gzip,hashlib
from pathlib import Path
import numpy as np

ROOT=Path('E:/IcarusWorldAudit/2026-09-06')
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()

def main(folder):
    summary=json.loads((folder/'summary.json').read_text());name=summary['map'];raw=np.load(ROOT/f'supplemented-v2/world/{name}/geometry.npz');p,f=raw['points'],raw['faces'];a=np.array(json.loads((ROOT/f'tactical-alignment-sides-v1/{name}.json').read_text())['nativeToAttackSvg']);allrows=[];maxres=0.;minweight=1.;maxweight=0.;triangles=0
    assert sha(ROOT/f'supplemented-v2/world/{name}/geometry.npz')==summary['sourceGeometrySha256']
    coverage_path=ROOT/f'tactical-visibility-revision/all-map-wall-span-coverage-v1/{name}/attack.coverage.json.gz'
    assert sha(coverage_path)==summary['sourceCoverageSha256']
    assert sha(Path(f'assets/maps/{name}_map.svg'))==summary['sourceArtworkSha256']
    expected=json.loads(gzip.decompress(coverage_path.read_bytes()))['spans']
    assert len({row['file'] for row in summary['components']})==len(summary['components']), 'Component files must not overwrite each other'
    component_keys=[]
    for descriptor in summary['components']:
        path=folder/descriptor['file'];assert sha(path)==descriptor['sha256'];data=json.loads(gzip.decompress(path.read_bytes()));allrows.extend(data['spans'])
        component_keys.append((data['elementIndex'],data['component']))
        assert descriptor['component']==data['component']
        assert descriptor.get('elementIndex',data['elementIndex'])==data['elementIndex']
        assert descriptor['spanCount']==data['spanCount']==len(data['spans'])
        assert all((r['elementIndex'],r['component'])==component_keys[-1] for r in data['spans'])
        for join in data['joins']:assert join['authoredJoinErrorSvg']<1e-9
        for row in data['spans']:
            for plane in row['planes']:
                ids=np.array(plane['clippedTriangleSourceFaces'],dtype=np.int64);xyz=np.array(plane['sourceClippedTrianglesSvgZ']);assert len(ids)==len(xyz);assert set(ids)<=set(plane['expandedSourceFaces'])
                if not len(ids):continue
                triangles+=len(ids);original=p[f[ids]].copy();original[:,:,:2]=original[:,:,:2]@a[:,:2].T+a[:,2];base=original[:,0];basis=np.stack([original[:,1]-base,original[:,2]-base],axis=2);coordinates=np.einsum('nij,nkj->nki',np.linalg.pinv(basis),xyz-base[:,None,:]);reconstructed=base[:,None,:]+np.einsum('nij,nkj->nki',basis,coordinates);weights=np.concatenate([1-coordinates.sum(2,keepdims=True),coordinates],axis=2)
                maxres=max(maxres,float(np.linalg.norm(reconstructed-xyz,axis=2).max()));minweight=min(minweight,float(weights.min()));maxweight=max(maxweight,float(weights.max()))
    assert len(allrows)==summary['completeSpanCount']==len({r['completeSpan'] for r in allrows});assert maxres<1e-7 and minweight>=-1e-6 and maxweight<=1+1e-6
    assert len(component_keys)==len(set(component_keys))==summary['componentCount']
    assert {(r['elementIndex'],r['component'],r['completeSpan']) for r in allrows}=={(r['elementIndex'],r['subpath'],r['span']) for r in expected}
    regressions={}
    if name=='split':
        short=next(r for r in allrows if r['completeSpan']==99);assert short['legacyStraightEdgeIndex'] is None and short['segmentType']=='Line' and abs(short['lengthSvg']-1.064)<1e-8;regressions['realShortReturn99Retained']=True
        wall=next(r for r in allrows if r['legacyStraightEdgeIndex']==90);secondary=[g for g in wall['planes'] if g['sourceObjectIndex']==5919 and 1892878 in g['seedSourceFaces']];assert len(secondary)==1 and secondary[0]['status']=='ambiguous-plane' and 'endpoint-only-plane-do-not-assign-whole-wall' in secondary[0]['reasons'];regressions['separateLowLedge90NotAutoAssigned']=True
        assert len(allrows)==228 and summary['componentCount']==10;regressions['all228SpansAcross10ComponentsAccounted']=True
    result=dict(scope='Checks source coordinates, source-face correspondence, closed authored component graph, complete coverage, and known secondary90/short99 regressions. Does not accept source ownership or gameplay behavior.',sourceGeometrySha256=summary['sourceGeometrySha256'],summarySha256=sha(folder/'summary.json'),verifierSha256=sha(Path(__file__)),clippedTrianglesChecked=triangles,maxSourceCoordinateResidualSvgZ=maxres,minimumOriginalBarycentricWeight=minweight,maximumOriginalBarycentricWeight=maxweight,regressions=regressions);(folder/'proposal-integrity.json').write_text(json.dumps(result,indent=2));print(result)

if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('folder',type=Path);args=p.parse_args();main(args.folder)

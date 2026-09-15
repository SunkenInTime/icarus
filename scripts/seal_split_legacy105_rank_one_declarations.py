"""Freeze explicit scalar maps for intended collapsed105 proposal cells."""
import copy
import json

import numpy as np

from declare_split_legacy105_connected_region import REV, sha
from verify_region_mapping import verify_rank_one_declarations, verify_region_topology
from tactical_alignment_composite import explicit_warp
import gzip


def seal(family):
    result=copy.deepcopy(family)
    source=np.array(family['sourceVerticesSvg']);target=np.array(family['targetVerticesSvg']);cells=np.array(family['triangles'])
    def determinant(points):
        a=points[:,1]-points[:,0];b=points[:,2]-points[:,0]
        return a[:,0]*b[:,1]-a[:,1]*b[:,0]
    source_det=determinant(source[cells]);target_det=determinant(target[cells]);ratio=target_det/source_det
    declarations=[];point_cells=[];rows=[]
    for index in np.flatnonzero((target_det==0)|(ratio<0)):
        cell=cells[index];src=source[cell];dst=target[cell]
        distance=np.linalg.norm(dst[:,None]-dst[None,:],axis=2);ia,ib=np.unravel_index(distance.argmax(),distance.shape)
        if distance[ia,ib]==0:
            point_cells.append(int(index));rows.append(dict(cell=int(index),classification='exact-constant-point',target=dst[0].tolist(),literalSignedRatio=float(ratio[index])));continue
        a,b=dst[[ia,ib]];delta=b-a;parameters=(dst-a)@delta/(delta@delta)
        expected=a+parameters[:,None]*delta
        assert (abs(dst-expected)<=4*np.spacing(np.maximum(1.,abs(expected)))).all(), ('Not a line-collapse arithmetic residual',index)
        gradient=np.linalg.solve(src[1:]-src[:1],parameters[1:]-parameters[0]);norm=float(np.linalg.norm(gradient));assert norm>0
        tangent=gradient/norm;length=1/norm
        declarations.append(dict(id=f'legacy105-cell-{index}',targetEndpointsSvg=[a.tolist(),b.tolist()],
            targetEndpointVertexIds=[int(cell[ia]),int(cell[ib])],sourceOriginSvg=src[ia].tolist(),
            sourceTangent=tangent.tolist(),sourceLengthSvg=length,sourceEndpointArithmeticSvg=1e-12,
            cells=[dict(cell=int(index),vertexParameters=np.clip(parameters,0,1).tolist())]))
        rows.append(dict(cell=int(index),classification='explicit-scalar-line',literalTargetDeterminant=float(target_det[index]),literalSignedRatio=float(ratio[index]),
            maximumStoredLineEvaluationResidualSvg=float(abs(dst-expected).max())))
    result['declaredRankOneMappings']=declarations
    result['declaredConstantPointCells']=point_cells
    result['sourcePartitionMethod']='finite-convex-cells-v1'
    result['sourceCoordinateConstruction']='original-native-triangle-v1'
    assert 'sourceContainmentArithmeticPolicy' not in result
    verified=verify_rank_one_declarations(result)
    assert set(np.flatnonzero(ratio<0)).issubset(verified)
    proof=dict(exactConstantPointCells=len(point_cells),explicitScalarLineCells=len(verified),literalNegativeCells=int((ratio<0).sum()),
        minimumLiteralSignedRatio=float(ratio.min()),maximumStoredLineEvaluationResidualSvg=max((r['maximumStoredTargetResidualSvg'] for r in verified.values()),default=0),
        sourceVerticesBitwiseUnchanged=np.array_equal(source,np.array(result['sourceVerticesSvg'])),
        targetVerticesBitwiseUnchanged=np.array_equal(target,np.array(result['targetVerticesSvg'])),
        sourceCellsBitwiseUnchanged=np.array_equal(cells,np.array(result['triangles'])),cells=rows,
        semantics='Exact point cells keep their constant stored target. Line cells now use explicit scalar interpolation, independently verified against stored targets within four coordinate ULPs. Positive-area cells are unchanged; no geometric tolerance is increased.',
        nativeConstruction='Require original-native-triangle-v1 and finite-convex-cells-v1. No barrier-only coordinate certificate is opted in.')
    return result,proof


if __name__=='__main__':
    source_path=REV/'split-legacy105-connected-region-proposal-v5/combined-declarations.json'
    out=REV/'split-legacy105-connected-region-proposal-v6';out.mkdir(exist_ok=False)
    families=json.loads(source_path.read_text());sealed=[];proofs=[]
    wp=REV/'display-warps-v1/split.display-warp.json.gz';w=json.loads(gzip.decompress(wp.read_bytes()));matrix=np.column_stack((w['projection']['axisU'],w['projection']['axisV']));origin=np.array(w['projection']['origin'])
    ws=np.array(w['sourceNativeMeters']).reshape(-1,2)@matrix.T+origin;wt=np.array(w['targetAttackSvg']).reshape(-1,2);wc=np.array(w['triangles']).reshape(-1,3);forward=explicit_warp(ws,wt-ws,wc)
    for family in families:
        result,proof=seal(family);proof['topology']=verify_region_topology(result,forward);sealed.append(result);proofs.append(proof)
    for name,family in zip(['region-declaration.json','bottom-continuation-declaration.json'],sealed):
        (out/name).write_text(json.dumps(family,indent=2)+'\n')
    (out/'combined-declarations.json').write_text(json.dumps(sealed,indent=2)+'\n')
    (out/'rank-classification-review.json').write_text(json.dumps(dict(sourceDeclarationsSha256=sha(source_path),scriptSha256=sha(__import__('pathlib').Path(__file__)),families=proofs),indent=2)+'\n')
    print(json.dumps([{k:v for k,v in p.items() if k not in ['cells','topology']} for p in proofs]))

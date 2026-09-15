"""Exact fallback for a source-cell test built from stored source provenance."""
from fractions import Fraction
import hashlib
import math
import numpy as np
from verify_source_cell_coordinate_certificate import certify_coordinate_error


def fraction(value):return Fraction(*float(value).as_integer_ratio())
def encoded(value):return dict(numerator=str(value.numerator),denominator=str(value.denominator),decimal=float(value))
def digest(array):return hashlib.sha256(np.ascontiguousarray(array,dtype='<f8').tobytes()).hexdigest()


def exact_weights(original,bary,matrix,origin,cell):
    """Compose the stored native affine and barycentric construction exactly."""
    o=[[fraction(x) for x in row] for row in original];b=[[fraction(x) for x in row] for row in bary];m=[[fraction(x) for x in row] for row in matrix];offset=[fraction(x) for x in origin];c=[[fraction(x) for x in row] for row in cell]
    e=[c[1][j]-c[0][j] for j in range(2)];f=[c[2][j]-c[0][j] for j in range(2)];det=e[0]*f[1]-e[1]*f[0]
    assert det!=0,'Degenerate declared source cell'
    result=[]
    for weights in b:
        xyz=[o[0][j]+sum(weights[k]*(o[k][j]-o[0][j]) for k in [1,2]) for j in range(2)]
        p=[sum(m[j][k]*xyz[k] for k in range(2))+offset[j]-c[0][j] for j in range(2)]
        u=(p[0]*f[1]-p[1]*f[0])/det;v=(e[0]*p[1]-e[1]*p[0])/det;result.append([1-u-v,u,v])
    return result


def certify_storage_extension(family, cell, vertex_weights):
    """Bound cell escape and its mapped displacement in coordinate storage units.

    A thin cell can amplify sub-ulp coordinate residue into a large negative
    barycentric weight. Measure the actual displacement without moving a vertex.
    Topology, source partition and authored wall contact remain separate gates.
    """
    ids=family['triangles'][cell]
    source=[[fraction(x) for x in family['sourceVerticesSvg'][i]] for i in ids]
    target=[[fraction(x) for x in family['targetVerticesSvg'][i]] for i in ids]
    for declaration in family.get('declaredRankOneMappings', []):
        for row in declaration['cells']:
            if row['cell']==cell:
                a,b=[[fraction(x) for x in p] for p in declaration['targetEndpointsSvg']]
                target=[[a[k]+fraction(t)*(b[k]-a[k]) for k in range(2)] for t in row['vertexParameters']]
    def mapped(w, triangle):return [sum(w[i]*triangle[i][k] for i in range(3)) for k in range(2)]
    records=[]
    for weights in vertex_weights:
        point=mapped(weights, source);shown=mapped(weights, target)
        distance=extension=Fraction(0)
        if min(weights)<0:
            candidates=[]
            for i,j in [(0,1),(1,2),(2,0)]:
                delta=[source[j][k]-source[i][k] for k in range(2)]
                parameter=sum((point[k]-source[i][k])*delta[k] for k in range(2))/sum(x*x for x in delta)
                parameter=max(Fraction(0),min(Fraction(1),parameter))
                nearest=[source[i][k]+parameter*delta[k] for k in range(2)]
                shown_nearest=[target[i][k]+parameter*(target[j][k]-target[i][k]) for k in range(2)]
                candidates.append((sum((point[k]-nearest[k])**2 for k in range(2)),sum((shown[k]-shown_nearest[k])**2 for k in range(2))))
            distance,extension=min(candidates)
        source_budget=sum(fraction(math.ulp(float(x)))**2 for x in point)
        mapped_budget=sum(fraction(math.ulp(float(x)))**2 for x in shown)
        assert distance<=source_budget, 'Source-cell escape exceeds coordinate storage precision'
        assert extension<=mapped_budget, 'Mapped cell extension exceeds coordinate storage precision'
        records.append(dict(exactSquaredOutsideDistance=encoded(distance),exactSquaredStorageBudget=encoded(source_budget),exactSquaredMappedExtension=encoded(extension),exactSquaredMappedStorageBudget=encoded(mapped_budget)))
    return dict(policy='source-and-mapped-one-binary64-XY-storage-interval',declaredCell=cell,vertices=records,
        maximumMappedExtensionErrorSvg=max(math.sqrt(r['exactSquaredMappedExtension']['decimal']) for r in records),
        scope='Exact distance to the declared source cell and its affine mapped displacement to the closest cell point. Coordinates and weights are retained; no geometric tolerance or declaration change.')


def certify_vertex_weights(points,cells,construction=None):
    points=np.asarray(points,dtype=float);cells=np.asarray(cells,dtype=float)
    basis=np.stack((cells[:,1]-cells[:,0],cells[:,2]-cells[:,0]),axis=2)
    uv=np.linalg.solve(basis[:,None],(points-cells[:,:1])[...,None])[...,0]
    weights=np.concatenate((1-uv.sum(2,keepdims=True),uv),axis=2);double_min=float(weights.min(initial=0));flagged=np.flatnonzero(weights.min((1,2)) < -1e-8);records=[]
    if len(flagged):
        assert construction is not None,('region fragment crosses its declared source cell',double_min)
        original=np.asarray(construction['originalNativeTriangles'],dtype=float);bary=np.asarray(construction['sourceBarycentrics'],dtype=float);matrix=np.asarray(construction['projectionMatrix'],dtype=float);origin=np.asarray(construction['projectionOrigin'],dtype=float)
        assert original.shape==bary.shape==(len(points),3,3) and matrix.shape==(2,2) and origin.shape==(2,)
        assert all(np.isfinite(a).all() for a in [original,bary,matrix,origin])
        reconstructed=(original[:,:1]+np.einsum('nij,njk->nik',bary[:,:,1:],original[:,1:]-original[:,:1]))[:,:,:2]@matrix.T+origin
        assert np.array_equal(reconstructed,points),'Source construction does not reproduce the supplied source coordinates'
        for index in flagged:
            exact=exact_weights(original[index],bary[index],matrix,origin,cells[index]);minimum=min(x for row in exact for x in row)
            record=dict(fragmentRow=int(index),sourceParent=int(construction['sourceParents'][index]),regionCell=int(construction['regionCells'][index]),doubleMinimum=float(weights[index].min()),exactMinimum=encoded(minimum),inputHashes=dict(originalNativeTriangle=digest(original[index]),sourceBarycentrics=digest(bary[index]),projectionMatrix=digest(matrix),projectionOrigin=digest(origin),declaredSourceCell=digest(cells[index])),provenanceHashes=construction['inputHashes'])
            records.append(record)
            if minimum < fraction(-1e-8):
                family=construction.get('family', {})
                assert family,('Exact source construction crosses its declared cell',record)
                cell=int(construction['regionCells'][index])
                assert 0<=cell<len(family['triangles']), 'Exact source construction crosses an invalid declared cell'
                declared=np.asarray(family['sourceVerticesSvg'])[np.asarray(family['triangles'])[cell]]
                assert np.array_equal(declared,cells[index]), 'Coordinate certificate cell differs from tested cell'
                if family.get('sourceContainmentArithmeticPolicy'):
                    certified,proof=certify_coordinate_error(family,original[index],bary[index],matrix,origin,cell)
                    assert certified==[[float(x) for x in row] for row in exact]
                else:
                    proof=certify_storage_extension(family,cell,exact)
                record['coordinateErrorCertificate']=proof
            weights[index]=np.array([[float(x) for x in row] for row in exact])
    exempt={r['fragmentRow'] for r in records if 'coordinateErrorCertificate' in r}
    assert all(i in exempt or weights[i].min()>=-1e-8 for i in flagged)
    minimum=float(weights.min(initial=0))
    bound=max((r['coordinateErrorCertificate']['maximumMappedExtensionErrorSvg'] for r in records if 'coordinateErrorCertificate' in r),default=0.)
    return weights,dict(doubleMinimum=double_min,certifiedVertexMinimum=minimum,exactFallbacks=records,coordinateCertifiedFragments=len(exempt),maximumMappedExtensionErrorSvg=bound,scope='Failed double vertex tests reconstruct stored source provenance exactly. Ordinary cells retain the -1e-8 gate. Explicit coordinate certificates separately bound storage-scale escapes and their mapped error; they do not assert exact containment. Source partition and displayed-wall contact remain separate checks.')

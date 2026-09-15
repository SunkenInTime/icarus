"""Compare unchanged reviewed-family outputs independently of BVH ordering."""
import hashlib
import json
from pathlib import Path
import numpy as np
from tactical_alignment_audit import pack
from native_compact_wall_profiles import sha

REV=Path('E:/IcarusWorldAudit/2026-09-06/tactical-visibility-revision')


def digest(records):
    result=hashlib.sha256()
    for row in sorted(records):
        result.update(len(row).to_bytes(8,'little'));result.update(row)
    return result.hexdigest()


def inventory(folder,edges):
    _,arrays=pack(folder/'split.height.bin.gz')
    proof=dict(np.load(folder/'normalized-face-provenance.npz'))
    source=np.load(folder/'correspondence.npz')['sourceFaces']
    output={}
    for edge in edges:
        generated=[];discarded=[]
        for row in np.flatnonzero(proof['generatedEdges']==edge):
            face=proof['generatedFaceIds'][row];mask=int(arrays['faceMasks'][face])
            meta=np.array([source[face],edge,proof['generatedWarpCells'][row],proof['generatedRegionCells'][row],
                -1 if mask<0 else arrays['maskedMaterials'][mask]],dtype='<i8')
            uvs=np.zeros((3,2),dtype='<f8') if mask<0 else arrays['maskedUvs'][mask].astype('<f8')
            generated.append(meta.tobytes()+proof['generatedBarycentrics'][row].astype('<f8').tobytes()+
                arrays['vertices'][arrays['faces'][face]].astype('<f8').tobytes()+uvs.tobytes())
        for row in np.flatnonzero(proof['discardedEdges']==edge):
            meta=np.array([proof['discardedSourceFaces'][row],edge,proof['discardedRegionCells'][row]],dtype='<i8')
            discarded.append(meta.tobytes()+proof['discardedBarycentrics'][row].astype('<f8').tobytes())
        output[edge]=dict(generatedCount=len(generated),generatedDigest=digest(generated),
            discardedCount=len(discarded),discardedDigest=digest(discarded))
    return output


def main():
    stage=REV/'split-pipe-generator-planks-stage-v30/stage.json'
    edges=json.loads(stage.read_text())['unchangedFamilyEdges'];assert len(edges)==31
    a=REV/'split-wall-family-normalized-candidate-v29';b=REV/'split-wall-family-normalized-candidate-v30-cached-v1'
    before=inventory(a,edges);after=inventory(b,edges)
    rows=[dict(edge=edge,before=before[edge],after=after[edge],bitwiseEqual=before[edge]==after[edge]) for edge in edges]
    report=dict(sourcePackSha256=sha(a/'split.height.bin.gz'),candidatePackSha256=sha(b/'split.height.bin.gz'),rows=rows,
        scope='Literal multiset bytes for generated XYZ, source barycentrics/parent, W/region cells, effective material/UV and discarded source barycentrics. Ignores BVH face order and remapped vertex/mask indices only.',
        productionMutation=False)
    (b/'unchanged-31-family-byte-review.json').write_text(json.dumps(report,indent=2)+'\n')
    print(json.dumps(dict(families=len(rows),generated=sum(r['before']['generatedCount'] for r in rows),
        discarded=sum(r['before']['discardedCount'] for r in rows),failures=[r for r in rows if not r['bitwiseEqual']]),indent=2))
    assert all(r['bitwiseEqual'] for r in rows),'Unchanged family byte mismatch; inspect saved report'


if __name__=='__main__':main()

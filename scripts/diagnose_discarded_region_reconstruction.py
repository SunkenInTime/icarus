"""Compare independent source interpolation orders without changing a gate."""
import json,gzip,sys
from pathlib import Path
import numpy as np
from tactical_alignment_audit import pack
from prepare_ascent_connected_corners import REV

folder=Path(sys.argv[-1]) if not sys.argv[-1].startswith('--') and len(sys.argv)>2 else REV/'ascent-connected-boat-candidate-v2';binding=json.loads((folder/'bindings.json').read_text());f=binding['families'][0];_,source=pack(Path(binding['sourceBackup']));p=np.load(folder/'normalized-face-provenance.npz');generated='--generated' in sys.argv;mode='generated' if generated else 'discarded';b=p[mode+'Barycentrics'];parents=np.load(folder/'correspondence.npz')['sourceFaces'][p['generatedFaceIds']] if generated else p['discardedSourceFaces'];cell_ids=p[mode+'RegionCells'];active=cell_ids>=0;b=b[active];parents=parents[active];cell_ids=cell_ids[active];original=source['vertices'][source['faces'][parents]];w=json.loads(gzip.decompress((REV/'display-warps-v1/ascent.display-warp.json.gz').read_bytes()));m=np.column_stack((w['projection']['axisU'],w['projection']['axisV']));o=np.asarray(w['projection']['origin']);grid=np.asarray(f['sourceVerticesSvg']);cells=np.asarray(f['triangles'])[cell_ids];tri=grid[cells];basis=np.stack((tri[:,1]-tri[:,0],tri[:,2]-tri[:,0]),axis=2)
weighted=np.einsum('nij,njk->nik',b,original)[:,:,:2]@m.T+o
anchored=(original[:,:1]+np.einsum('nij,njk->nik',b[:,:,1:],original[:,1:]-original[:,:1]))[:,:,:2]@m.T+o
svg=original[:,:,:2]@m.T+o;svg_anchored=svg[:,:1]+np.einsum('nij,njk->nik',b[:,:,1:],svg[:,1:]-svg[:,:1])
variants={}
for name,points in [('weightedNative',weighted),('anchoredNative',anchored),('anchoredSvg',svg_anchored)]:
    uv=np.linalg.solve(basis[:,None],(points-tri[:,:1])[...,None])[...,0];weights=np.concatenate((1-uv.sum(2,keepdims=True),uv),axis=2);variants[name]=weights
bad=np.flatnonzero(np.minimum(variants['weightedNative'].min((1,2)),variants['anchoredNative'].min((1,2)))<-1e-8)
report=dict(rows=[dict(row=int(i),sourceParent=int(parents[i]),regionCell=int(cell_ids[i]),minimumWeights={k:float(v[i].min()) for k,v in variants.items()},maximumCoordinateDifferenceSvg=float(abs(weighted[i]-svg_anchored[i]).max()),sourceCell=tri[i].tolist()) for i in bad],globalMinima={k:float(v.min()) for k,v in variants.items()})
from decimal import Decimal,localcontext
def decimal_weights(index):
    with localcontext() as ctx:
        ctx.prec=60;D=Decimal.from_float;tt=[[D(float(x)) for x in row] for row in tri[index]];basis1=[tt[1][j]-tt[0][j] for j in range(2)];basis2=[tt[2][j]-tt[0][j] for j in range(2)];det=basis1[0]*basis2[1]-basis1[1]*basis2[0];out=[]
        for bary in b[index]:
            xyz=[D(float(original[index,0,j]))+sum(D(float(bary[k]))*(D(float(original[index,k,j]))-D(float(original[index,0,j]))) for k in [1,2]) for j in range(2)]
            p=[sum(D(float(m[j,k]))*xyz[k] for k in range(2))+D(float(o[j]))-tt[0][j] for j in range(2)]
            u=(p[0]*basis2[1]-p[1]*basis2[0])/det;v=(basis1[0]*p[1]-basis1[1]*p[0])/det;out.extend([1-u-v,u,v])
        return min(out)
for row in report['rows']:row['highPrecisionComposedMinimum']=str(decimal_weights(row['row']))
report['minimumHighPrecisionAtFlaggedRows']=min((float(r['highPrecisionComposedMinimum']) for r in report['rows']),default=0.)
(folder/f'{mode}-region-reconstruction-diagnostic.json').write_text(json.dumps(report,indent=2)+'\n');print(json.dumps(report,indent=2))


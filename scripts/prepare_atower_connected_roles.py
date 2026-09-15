"""Exact clipped source profiles for the reviewed Split84/85/86 junction."""
import hashlib
import json
from pathlib import Path
import numpy as np
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
from build_split_normalized_wall_families import cut

ROOT=Path('E:/IcarusWorldAudit/2026-09-06');REV=ROOT/'tactical-visibility-revision'


def main():
    out=REV/'split-multiplane-corner-proposals-v1'
    path=ROOT/'supplemented-v2/world/split/geometry.npz';raw=np.load(path);points,faces=raw['points'],raw['faces'];meta=json.loads(path.with_suffix('.json').read_text());obj=meta['objects'][5932]
    affine=np.array(json.loads((ROOT/'tactical-alignment-sides-v1/split.json').read_text())['nativeToAttackSvg']);matrix,origin=affine[:,:2],affine[:,2]
    families=[dict(edge=85,box=[324.2514863932356,183.078124196902,326.2045,185.12654962],axis=1,sourceAlong=[183.13925675576914,185.12654962],targetAlong=[181.742,183.869],fixed=325.858),dict(edge=86,box=[324.2514863932356,184.308,332.10036,185.482],axis=0,sourceAlong=[324.2514863932356,332.10036],targetAlong=[325.858,333.3],fixed=183.869)]
    for family in families:family.update(sourceFaces=[],sourceFragments=[],sourceDepthFaces=[])
    unresolved=[]
    for fid in range(obj['firstFace'],obj['firstFace']+obj['faceCount']):
        xyz=points[faces[fid]];normal=np.cross(xyz[1]-xyz[0],xyz[2]-xyz[0]);normal/=np.linalg.norm(normal)
        data=np.column_stack((xyz,np.eye(3)));data[:,:2]=xyz[:,:2]@matrix.T+origin
        pieces=[list(data)]
        for family in families:
            remaining=[]
            for piece in pieces:
                inside,other=cut(piece,family['box'])
                if len(inside)<3:remaining.extend(other);continue
                p=np.array(inside);extent=p[:,:3]
                area=sum(np.linalg.norm(np.cross(extent[i]-extent[0],extent[i+1]-extent[0])) for i in range(1,len(p)-1))
                if area<1e-12:remaining.append(piece);continue
                near_axis=abs(normal[2])<.02 and min(abs(normal[:2]))<.001*max(abs(normal[:2]))
                along_axis=int(np.argmin(abs(normal[:2])))
                top_depth=family['edge']==85 and abs(normal[1])>.999 and np.max(abs(p[:,1]-183.078124196902))<.001
                if not ((near_axis and along_axis==family['axis']) or top_depth):
                    remaining.append(piece)
                    unresolved.append(dict(sourceFace=fid,nearEdge=family['edge'],normalNative=normal.tolist(),clippedSourceVerticesSvgZ=p[:,:3].tolist(),clippedOriginalBarycentrics=p[:,3:].tolist()))
                    continue
                remaining.extend(other)
                family['sourceFaces'].append(fid)
                if top_depth:family['sourceDepthFaces'].append(fid)
                family['sourceFragments'].append(dict(sourceFace=fid,normalNative=normal.tolist(),sourceVerticesSvgZ=p[:,:3].tolist(),originalBarycentrics=p[:,3:].tolist(),role='attached top depth at84/85' if top_depth else 'parallel wall plane'))
            pieces=remaining
    for family in families:
        family['sourceFaces']=sorted(set(family['sourceFaces']));family['sourceDepthFaces']=sorted(set(family['sourceDepthFaces']))
    proof=dict(map='split',sourceGeometrySha256=meta['geometrySha256'],generatorSha256=hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),sourceObject=dict(sourceObjectIndex=5932,**obj),families=families,unresolvedNearbyFragments=unresolved,sourceJunctions=[dict(edges=[84,85],sourceSvg=[324.2514863932356,183.13925675576914],targetSvg=[325.858,181.742]),dict(edges=[85,86],sourceSvg=[324.2514863932356,185.12654962],targetSvg=[325.858,183.869])],unresolvedFrontier=dict(edges=[86,87],sourceObject87=5918,targetSvg=[333.3,183.869],reason='The unchanged source87 return is connected to the original86 frontage. A new86-only endpoint can detach it; closure must be checked before accepting a connected candidate.'),status='review proposal only; no geometry bake',scope='Each source fragment keeps original raw-source XYZ and barycentrics. Expanded vertical planes at higher levels remain separate profiles. Non-axis facets and horizontal caps remain explicit pending source-role review, not silently assigned.')
    (out/'atower-connected-profile-proposal.json').write_text(json.dumps(proof,indent=2))
    fig,axes=plt.subplots(2,2,figsize=(15,10))
    for row,family in enumerate(families):
        axis=family['axis'];s0,s1=family['sourceAlong'];t0,t1=family['targetAlong']
        for fragment in family['sourceFragments']:
            p=np.array(fragment['sourceVerticesSvgZ']);along=p[:,axis];mapped=t0+np.clip((along-s0)/(s1-s0),0,1)*(t1-t0)
            for col,x in enumerate([along,mapped]):axes[row,col].fill(x,p[:,2],color='#0284c7',alpha=.25);axes[row,col].plot(np.r_[x,x[0]],np.r_[p[:,2],p[0,2]],color='#075985',linewidth=.5)
        axes[row,0].set_title(f"Edge{family['edge']}: {len(family['sourceFaces'])} exact source faces, before")
        axes[row,1].set_title('Proposed canonical profile; every source height retained')
        for ax in axes[row]:ax.set_xlabel('Along wall in SVG units');ax.set_ylabel('Original source Z, metres');ax.grid(alpha=.2)
    fig.suptitle('Split84/85/86 connected profile proposal. Blue is selected source geometry. Caps and86/87 closure remain explicit review gates.');fig.tight_layout(rect=[0,0,1,.96]);fig.savefig(out/'atower-connected-height-profiles.png',dpi=160);plt.close(fig)
    print({family['edge']:len(family['sourceFaces']) for family in families},'unresolved fragments',len(unresolved))


if __name__=='__main__':main()

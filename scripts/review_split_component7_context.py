"""Read-only full source context for Split component7 before ownership decisions."""
import gzip,hashlib,json
from pathlib import Path
import numpy as np
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
from matplotlib.collections import LineCollection
from mpl_toolkits.mplot3d.art3d import Poly3DCollection
from render_competing_floor_assemblies import clip_mesh_xy
from render_split_remaining_corner_families import sections
from build_split_connected_tower import ROOT,REV

def main():
    out=REV/'split-component7-source-review-v1';out.mkdir(exist_ok=True)
    proposal_path=REV/'split-connected-contour-proposals-v2/component-7.json.gz';proposal=json.loads(gzip.decompress(proposal_path.read_bytes()));raw_path=ROOT/'supplemented-v2/world/split/geometry.npz';raw=np.load(raw_path);p,f=raw['points'],raw['faces'];meta=json.loads(raw_path.with_suffix('.json').read_text());affine=np.array(json.loads((ROOT/'tactical-alignment-sides-v1/split.json').read_text())['nativeToAttackSvg'])
    groups=[('Hostel corner',[6726,6727,7205,7115],[86,97,125,142]),('Tower and balcony',[6966,6946,6838,6831],[108,125,180,188])]
    object_ids=sorted(set(i for _,ids,_ in groups for i in ids));meshes={};faceids={};objects=[]
    for obj in object_ids:
        row=meta['objects'][obj];ids=np.arange(row['firstFace'],row['firstFace']+row['faceCount']);tri=p[f[ids]].copy();tri[:,:,:2]=tri[:,:,:2]@affine[:,:2].T+affine[:,2];meshes[obj]=tri;faceids[obj]=ids
        objects.append(dict(index=obj,**row,projectedBounds=np.stack((tri.min((0,1)),tri.max((0,1)))).tolist()))
    np.savez_compressed(out/'full-source-context.npz',sourceFaceIds=np.concatenate([faceids[i] for i in object_ids]),sourceObjectIds=np.concatenate([np.full(len(faceids[i]),i) for i in object_ids]),trianglesSvgSourceZ=np.concatenate([meshes[i] for i in object_ids]))
    def outline(ax,bounds):
        for span in proposal['spans']:
            line=np.array(span['authoredEndpoints'])
            if (line.max(0)>=bounds[:2]).all() and (line.min(0)<=bounds[2:]).all():ax.plot(*line.T,color='#111827',lw=2.2);ax.text(*line.mean(0),str(span['completeSpan']),fontsize=8,clip_on=True)
    for title,ids,bounds in groups:
        fig=plt.figure(figsize=(18,12));colors={obj:plt.cm.tab10(i) for i,obj in enumerate(ids)}
        for i in range(2):
            ax=fig.add_subplot(2,3,1+i*3,projection='3d')
            for obj in ids:
                tri=clip_mesh_xy(meshes[obj],np.array(bounds[:2]),np.array(bounds[2:]));ax.add_collection3d(Poly3DCollection(tri,facecolors=colors[obj],edgecolors=colors[obj],alpha=.3,linewidths=.13))
            ax.set_xlim(bounds[0],bounds[2]);ax.set_ylim(bounds[1],bounds[3]);ax.set_zlim(3,30 if title.startswith('Tower') else 14);ax.view_init(25,-65 if i==0 else 115);ax.set_box_aspect([bounds[2]-bounds[0],bounds[3]-bounds[1],(27 if title.startswith('Tower') else 11)*3.91]);ax.set_title('Original source, angle'+str(i+1));ax.set_xlabel('Pre-W SVG X');ax.set_ylabel('Pre-W SVG Y');ax.set_zlabel('Absolute source Z,m')
        for i,z in enumerate([5.75,9.75,11.75,15.75]):
            ax=fig.add_subplot(2,3,[2,3,5,6][i]);outline(ax,bounds)
            for obj in ids:
                lines,_=sections(meshes[obj],z)
                if len(lines):ax.add_collection(LineCollection(lines,colors=[colors[obj]],lw=1,label=f'{obj} {meta["objects"][obj]["path"].split("/")[-2]}'))
            ax.set_xlim(bounds[0],bounds[2]);ax.set_ylim(bounds[3],bounds[1]);ax.set_aspect('equal');ax.grid(alpha=.2);ax.set_title(f'Raw source Z={z}m');ax.legend(fontsize=7)
        fig.suptitle(title+' | source context only, no mapping or wall-role acceptance.\nBlack is authored component7. Sections show mesh surfaces without alpha sampling; heights are absolute source values.',fontsize=12);fig.tight_layout(rect=[0,0,1,.95]);fig.savefig(out/(title.lower().replace(' ','-')+'.png'),dpi=160);plt.close(fig)
    rows=[]
    for span in proposal['spans']:
        planes=[]
        for i,plane in enumerate(span['planes']):
            planes.append(dict(planeIndex=i,sourceObjectIndex=plane['sourceObjectIndex'],sourceObject=plane['sourceObject'],sourcePlane=plane['sourcePlane'],seedSourceFaces=plane['seedSourceFaces'],expandedSourceFaces=plane['expandedSourceFaces'],sourceProjectedAlongInterval=plane['sourceProjectedAlongInterval'],standingInteriorPositionCount=plane['standingInteriorPositionCount'],reasons=plane['reasons'],primaryProposal=i in span['primaryPlaneCandidates']))
        rows.append(dict(completeSpan=span['completeSpan'],authoredEndpoints=span['authoredEndpoints'],planes=planes))
    report=dict(scope='Read-only connected source context, not geometry membership approval. Full source instances are preserved in the packet so clipping cannot hide adjoining floors, caps or openings.',sourceGeometrySha256=hashlib.sha256(raw_path.read_bytes()).hexdigest(),sourceProposalSha256=hashlib.sha256(proposal_path.read_bytes()).hexdigest(),objects=objects,spans=rows,concerns=['Tower6966 extends well beyond this authored component and spans absoluteZ4.5..29.34; whole-object movement cannot be assumed from one first-contact wall.','The balcony6946 and wrap6831 have different lower heights; source profile and alpha policy must be distinguished before admitting wrap as a wall family.','Door6838 and paper7115 are separate attached assemblies. No names-only role or dynamic-state assumption is made.'])
    (out/'source-context.json').write_text(json.dumps(report,indent=2));print(out)

if __name__=='__main__':main()

"""Held membership addition for source-backed vent wall sheets and panels."""
import json
from pathlib import Path
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
from mpl_toolkits.mplot3d.art3d import Poly3DCollection
import numpy as np
import shapely
from render_split_remaining_corner_families import sections
from render_competing_floor_assemblies import clip_mesh_xy
from lift_reviewed_wall_source_heights import sha

ROOT=Path('E:/IcarusWorldAudit/2026-09-06');REV=ROOT/'tactical-visibility-revision'


def main():
    prior=REV/'split-vent-room-finite-field-experiment-v5/sealed-held-region-declaration.json'
    out=REV/'split-vent-room-finite-field-experiment-v6';out.mkdir(exist_ok=False)
    family=json.loads(prior.read_text());raw_path=ROOT/'supplemented-v2/world/split/geometry.npz'
    raw=np.load(raw_path);points,faces=raw['points'],raw['faces'];meta=json.loads(raw_path.with_suffix('.json').read_text())
    projection=ROOT/'tactical-alignment-sides-v1/split.json';a=np.array(json.loads(projection.read_text())['nativeToAttackSvg'])
    full_corr=np.load(REV/'full-height-input-v1/split/source-correspondence.npz')['sourceFaces']
    added=[4776,7814,7789];rows=[];all_ids=[];all_tri=[]
    for obj in added:
        item=meta['objects'][obj];ids=np.arange(item['firstFace'],item['firstFace']+item['faceCount']);tri=points[faces[ids]].copy()
        tri[:,:,:2]=tri[:,:,:2]@a[:,:2].T+a[:,2];all_ids.extend(ids.tolist());all_tri.extend(tri)
        adjacent=[7796] if obj in [4776,7814] else [7795,7796]
        bounds=np.array([tri[:,:,:2].min((0,1))-.3,tri[:,:,:2].max((0,1))+.3]);back=[]
        for other in adjacent:
            o=meta['objects'][other];t=points[faces[o['firstFace']:o['firstFace']+o['faceCount']]].copy();t[:,:,:2]=t[:,:,:2]@a[:,:2].T+a[:,2]
            back.extend(clip_mesh_xy(t,*bounds))
        back=np.array(back);source_contacts=[]
        for z in [3.5,4.35,5.5,6.5,8.35,12.75]:
            ss,_=sections(tri,z);bb,_=sections(back,z)
            if not len(ss) or not len(bb):continue
            gs=shapely.union_all(shapely.linestrings(ss));gb=shapely.union_all(shapely.linestrings(bb));inter=gs.intersection(gb)
            source_contacts.append(dict(z=z,minimumSourceSectionDistanceSvg=float(gs.distance(gb)),sectionIntersectionLengthSvg=float(inter.length),intersectionCoordinates=shapely.get_coordinates(inter).tolist()))
        fig=plt.figure(figsize=(13,7))
        for number,az in enumerate([-65,115],1):
            ax=fig.add_subplot(1,2,number,projection='3d')
            ax.add_collection3d(Poly3DCollection(back,facecolors='#64748b',edgecolors='#64748b',lw=.15,alpha=.12))
            ax.add_collection3d(Poly3DCollection(tri,facecolors='#0d9488',edgecolors='#0f766e',lw=.5,alpha=.55))
            zlo,zhi=float(tri[:,:,2].min()),float(tri[:,:,2].max())
            ax.set(xlim=bounds[:,0],ylim=bounds[:,1],zlim=(zlo-.2,zhi+.2),xlabel='Original source SVG X',ylabel='Original source SVG Y',zlabel='Original Z, m')
            ax.set_box_aspect([*(bounds[1]-bounds[0]),(zhi-zlo+.4)*3.91]);ax.view_init(20,az)
        fig.suptitle(f'Original object {obj} in teal; nearby room backing in gray. No geometry moved.\n'
                     'Section overlap/proximity is recorded separately; no literal weld or collision role is assumed.',fontsize=11)
        fig.tight_layout();fig.savefig(out/f'original-wall-member-{obj}-source3d.png',dpi=145);plt.close(fig)
        rows.append(dict(index=obj,**item,admittedRawFacesInExistingFullPack=int(np.isin(ids,full_corr).sum()),sourceSectionContacts=source_contacts))
    prior_members=family['reviewedSourceFaces'][:]
    family['objects']=sorted(set(family['objects'])|set(added))
    family['reviewedSourceFaces']=sorted(set(prior_members)|set(all_ids))
    family['depthSourceFaces']=family['reviewedSourceFaces'][:]
    family['membershipRevision']=dict(priorDeclarationSha256=sha(prior),addedObjects=added,
        reason='All three objects are already admitted source wall geometry, and composed standing rays identified their contribution. Their original height, UV and material profiles must remain intact. This revision changes ownership only.',
        withheldTop172Object=5927,withheldAscenderCableObject=8317,
        limits='Held for independent original-height and source-neighbor review; not permission to bake.')
    sp=out/'sealed-held-region-declaration.json';sp.write_text(json.dumps(family,indent=2)+'\n')
    np.savez_compressed(out/'added-source-wall-objects.npz',rawSourceFaces=np.array(all_ids),trianglesSourceSvgZ=np.array(all_tri))
    old=json.loads(prior.read_text());keys=['sourceVerticesSvg','targetVerticesSvg','triangles','declaredRankOneMappings','declaredConstantPointCells','box']
    unchanged={key:old[key]==family[key] for key in keys};assert all(unchanged.values())
    report=dict(priorDeclarationSha256=sha(prior),declarationSha256=sha(sp),sourceGeometrySha256=sha(raw_path),sourceMetadataSha256=sha(raw_path.with_suffix('.json')),projectionSha256=sha(projection),scriptSha256=sha(Path(__file__)),
        fieldGeometryAndRankSemanticsUnchanged=unchanged,originalMemberFaces=len(prior_members),addedRawFaces=len(all_ids),totalRawFaces=len(family['reviewedSourceFaces']),objects=rows,
        status='Held membership-only proposal. No pack or production code changed. Full partition and composed standing ray replay must be repeated.',
        sourceRoles={'4776':'Existing lower wall sheet behind the173 frame; original2.683–5.669m height range retained.',
                     '7814':'Existing static wall panel behind the124 opening/frame; source height and materials retained.',
                     '7789':'Existing upper-level bottom wall assembly; complete30-face source remains the visibility reference.'})
    (out/'membership-review.json').write_text(json.dumps(report,indent=2)+'\n')
    print(json.dumps({k:val for k,val in report.items() if k!='objects'}))


if __name__=='__main__':main()

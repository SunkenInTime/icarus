"""Extend the existing generator front band over the complete attached curl."""
from copy import deepcopy
import gzip
import json
from pathlib import Path
import numpy as np
import shapely
from native_compact_wall_profiles import sha
from tactical_alignment_composite import explicit_warp
from verify_region_mapping import verify_region_topology

ROOT=Path('E:/IcarusWorldAudit/2026-09-06');REV=ROOT/'tactical-visibility-revision'


def main():
    out=REV/'split-generator-paper1640-complete-proposal-v2';out.mkdir(exist_ok=False)
    prior=REV/'split-generator-paper1640-attachment-proposal-v1/region-declaration.json'
    family=json.loads(prior.read_text());original=deepcopy(family)
    source=np.array(family['sourceVerticesSvg']);target=np.array(family['targetVerticesSvg']);cells=np.array(family['triangles'])
    raw=np.load(ROOT/'supplemented-v2/world/split/geometry.npz');meta=json.loads((ROOT/'supplemented-v2/world/split/geometry.json').read_text())
    p=np.array(json.loads((ROOT/'tactical-alignment-sides-v1/split.json').read_text())['nativeToAttackSvg'])
    obj=meta['objects'][1640];paper=raw['points'][raw['faces'][obj['firstFace']:obj['firstFace']+obj['faceCount']]]
    svg=paper[:,:,:2]@p[:,:2].T+p[:,2];minimum,maximum=svg.min((0,1)),svg.max((0,1))
    selected=np.flatnonzero(source[:,1]==187.2);x=source[selected,0]
    left=float(x[x<=minimum[0]].max());right=float(x[x>=maximum[0]].min())
    # Existing columns delimit both transitions. No new target cubic point,
    # cell, source face, source height or outer boundary is introduced.
    fade_left=float(x[x<41].max());fade_right=float(x[x>64].min())
    blend=np.minimum(np.clip((x-fade_left)/(left-fade_left),0,1),np.clip((fade_right-x)/(fade_right-right),0,1))
    proposed=source.copy();proposed[selected,1]+=blend*(maximum[1]-187.2)
    changed=np.flatnonzero(np.any(proposed!=source,axis=1));affected=np.flatnonzero(np.isin(cells,changed).any(1))
    family['sourceVerticesSvg']=proposed.tolist()
    for declaration in family['declaredRankOneMappings']:
        row=declaration['cells'][0];cell=row['cell']
        if cell not in set(affected):continue
        src=proposed[cells[cell]];parameters=np.array(row['vertexParameters']);dst=target[cells[cell]]
        ends=np.array(declaration['targetEndpointsSvg']);ia=int(np.argmin(np.linalg.norm(dst-ends[0],axis=1)))
        gradient=np.linalg.solve(src[1:]-src[:1],parameters[1:]-parameters[0]);norm=np.linalg.norm(gradient)
        declaration['sourceOriginSvg']=src[ia].tolist();declaration['sourceTangent']=(gradient/norm).tolist();declaration['sourceLengthSvg']=float(1/norm)
    wp=REV/'display-warps-v1/split.display-warp.json.gz';w=json.loads(gzip.decompress(wp.read_bytes()))
    matrix=np.column_stack([w['projection']['axisU'],w['projection']['axisV']]);offset=np.array(w['projection']['origin'])
    ws=np.array(w['sourceNativeMeters']).reshape(-1,2)@matrix.T+offset;wt=np.array(w['targetAttackSvg']).reshape(-1,2)
    forward=explicit_warp(ws,wt-ws,np.array(w['triangles']).reshape(-1,3))
    topology=verify_region_topology(family,forward)
    oldfield=explicit_warp(source,target-source,cells);newfield=explicit_warp(proposed,target-proposed,cells)
    domain=shapely.union_all(shapely.polygons(np.concatenate([source[cells[affected]],proposed[cells[affected]]])))
    inventories=[];mapped_differences=[]
    for owner in original['objects']:
        if owner==1640:continue
        item=meta['objects'][owner];ids=np.arange(item['firstFace'],item['firstFace']+item['faceCount']);tri=raw['points'][raw['faces'][ids]]
        xy=tri[:,:,:2]@p[:,:2].T+p[:,2]
        intersects=shapely.intersects(shapely.polygons(xy),domain)
        # Degenerate projected sheets are represented by their complete edges.
        for j in range(3):intersects|=shapely.intersects(shapely.linestrings(xy[:,[j,(j+1)%3]]),domain)
        ids=ids[intersects];xy=xy[intersects];maximum_change=0.;changed_faces=[]
        for face,triangle in zip(ids,xy):
            # Every old/new cell crossing along the projected face perimeter
            # is included. Interior overlaps are also explicitly inventoried.
            points=[*triangle]
            polygon=shapely.Polygon(triangle)
            for field in [oldfield,newfield]:
                for cell in field.tri.tree.query(polygon):
                    points.extend(shapely.get_coordinates(shapely.intersection(polygon,field.tri.polygons[cell])))
                for j in range(3):
                    edge=shapely.LineString(triangle[[j,(j+1)%3]])
                    for cell in field.tri.tree.query(edge):points.extend(shapely.get_coordinates(shapely.intersection(edge,field.tri.polygons[cell])))
            points=np.array(points);difference=float(np.max(np.linalg.norm(oldfield.apply(points)-newfield.apply(points),axis=1)))
            maximum_change=max(maximum_change,difference)
            if difference>1e-10:changed_faces.append(dict(rawFace=int(face),maximumMappedChangeSvg=difference))
        inventories.append(dict(sourceObject=owner,potentiallyAffectedRawFaces=ids.tolist(),changedFaces=changed_faces,maximumMappedChangeSvg=maximum_change))
        mapped_differences.extend(changed_faces)
    family['paperAttachmentReview'].update(status='Complete attached-paper proposal; local source-band extension includes every curled vertex. No bake.',
        changedSourceRow=187.2,newPlateauSourceY=float(maximum[1]),plateauSourceX=[left,right],fadeSourceX=[fade_left,fade_right],
        targetCoordinatesAndTopologyUnchanged=True,originalCubic204Unchanged=True)
    (out/'region-declaration.json').write_text(json.dumps(family,indent=2)+'\n')
    report=dict(priorProposalSha256=sha(prior),declarationSha256=sha(out/'region-declaration.json'),scriptSha256=sha(Path(__file__)),
        changedSourceVertices=changed.tolist(),affectedSourceCells=affected.tolist(),topology=topology,
        existingAssemblySourceReview=inventories,existingAssemblyChangedFaces=mapped_differences,
        sourceBand=dict(originalY=187.2,maximumY=float(maximum[1]),plateauX=[left,right],fadeX=[fade_left,fade_right]),
        targetVerticesBitwiseUnchanged=np.array_equal(target,np.array(original['targetVerticesSvg'])),cellsBitwiseUnchanged=family['triangles']==original['triangles'],
        acceptance='Proposed local finite field extension only. All source heights and cubic remain unchanged. Source fragment, contact and rendered review still required.')
    (out/'field-extension-review.json').write_text(json.dumps(report,indent=2)+'\n')
    print(json.dumps({k:v for k,v in report.items() if k not in ['topology','affectedSourceCells','changedSourceVertices','existingAssemblySourceReview']},indent=2))


if __name__=='__main__':main()

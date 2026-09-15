"""Record personal assembly-level Ascent source selections without baking geometry."""
import gzip,json
from collections import defaultdict
from pathlib import Path
from native_compact_wall_profiles import sha
from prepare_ascent_connected_corners import ROOT,REV,OUT

# These roles follow the personally viewed exact assembly geometry in
# assembly-source-page-1..8.png. Names or first-contact rank alone do not assign roles.
INSERTS={2729,2730,2731,2732,6374,6375,6384,6895,6896,6897,6923,6929}
GATES={964,965}
COLUMNS={667,668,669,670,4422}
ARCHES={6871,6872,7529,7530}
SEPARATE={6474:'Separate menu/sign plane; not the structural wall anchor.',7954:'Separate garden box; preserve its low source geometry, not a whole wall plane.'}


def main():
    folder=REV/'ascent-connected-contour-proposals-v1'
    assembly_path=OUT/'assembly-source-review.json';assemblies=json.loads(assembly_path.read_text())
    by_object={r['sourceObject']:r for r in assemblies['assemblies']}
    return_path=OUT/'structural-return-declarations.json';returns=json.loads(return_path.read_text());caps={d['completeSpan']:d for d in returns['declarations']}
    components=[];groups=defaultdict(list);source_owners=defaultdict(set)
    for component in [5,7]:
        path=folder/f'component-{component}.json.gz';data=json.loads(gzip.decompress(path.read_bytes()));spans=[]
        for row in data['spans']:
            selected=defaultdict(list);preserve=[]
            for index,plane in enumerate(row['planes']):
                obj=plane['sourceObjectIndex']
                if obj in SEPARATE:
                    preserve.append(dict(sourceObject=obj,sourceFaces=plane['expandedSourceFaces'],decision=SEPARATE[obj]));continue
                if plane['status']=='plane-proposal':selected[obj].append((index,plane))
            if row['completeSpan'] in caps:
                cap=caps[row['completeSpan']]
                # Short-return sparsity was resolved by exact structural source review,
                # not by lowering the generic nomination threshold.
                obj=cap['sourceObject'];allowed=set(cap['reviewedSourceFaces'])
                selected[obj]=[(i,g) for i,g in enumerate(row['planes']) if g['sourceObjectIndex']==obj and allowed.intersection(g['expandedSourceFaces'])]
            families=[]
            for obj,planes in selected.items():
                role='static-insert' if obj in INSERTS else 'open-metal-gate' if obj in GATES else 'structural-column' if obj in COLUMNS else 'structural-arch' if obj in ARCHES else 'structural-backing'
                face_ids=sorted({fid for _,g in planes for fid in g['expandedSourceFaces']})
                f=dict(id=f"ascent-component-{component}-span-{row['completeSpan']}-object-{obj}",sourceObject=obj,sourceObjectPath=by_object[obj]['sourceObjectPath'],role=role,planeProposals=[dict(index=i,sourcePlane=g['sourcePlane'],sourceFaces=g['expandedSourceFaces'],finiteReviewBoundsSvg=g['finiteReviewBoundsSvg'],sourceClippedTrianglesSvgZ=g['sourceClippedTrianglesSvgZ'],clippedTriangleSourceFaces=g['clippedTriangleSourceFaces']) for i,g in planes],sourceFaces=face_ids,reviewImage=str(OUT/f"assembly-source-page-{by_object[obj]['page']}.png"),reviewDecision='Selected from full source assembly review plus finite local contact evidence. Preserve every exact source height/material/UV profile; connected fragment ownership and normalization remain separate gates.',heightPolicy='No opaque extrusion. Gate bars, arch openings, windows, door relief and gaps remain source geometry.',ownershipState='finite source nominations selected; exact fragment partition and corner-cap assignments pending')
                if row['completeSpan'] in caps and obj==caps[row['completeSpan']]['sourceObject']:
                    f['finiteReturnDeclaration']=caps[row['completeSpan']]
                families.append(f);groups[obj].append(f['id'])
                for fid in face_ids:source_owners[fid].add(f['id'])
            unresolved=[]
            if not families:unresolved.append('No supported planar family; span208 needs the explicit nonplanar boat profile.')
            spans.append(dict(completeSpan=row['completeSpan'],authoredEndpoints=row['authoredEndpoints'],families=families,preserveSeparateSource=preserve,sourceSelectionComplete=bool(families),unresolved=unresolved,bakeAllowed=False))
        joins=[]
        for left,right in zip(spans,spans[1:]+spans[:1]):
            assert left['authoredEndpoints'][1]==right['authoredEndpoints'][0]
            common={f['sourceObject'] for f in left['families']} & {f['sourceObject'] for f in right['families']}
            joins.append(dict(leftSpan=left['completeSpan'],rightSpan=right['completeSpan'],targetSvg=left['authoredEndpoints'][1],commonSourceAssemblies=sorted(common),policy='Use exact shared body/bevel source seams for the nominated assemblies. Across different assemblies verify combined source height coverage. Do not let an unmodified outside fragment keep an incompatible source join.',status='finite-join-mapping-pending'))
        components.append(dict(component=component,spans=spans,joins=joins))
    conflicts=[dict(sourceFace=fid,families=sorted(owners),requiredAction='Split this exact source triangle into finite nonoverlapping barycentric fragments before assigning target families.') for fid,owners in source_owners.items() if len(owners)>1]
    report=dict(format='icarus-connected-source-family-selection-v1',map='ascent',components=components,sourceAssemblies=[dict(sourceObject=obj,families=ids) for obj,ids in sorted(groups.items())],finiteFragmentConflicts=conflicts,sourceFileSha256=assemblies['sourceFileSha256'],sourceAssemblyReviewSha256=sha(assembly_path),returnDeclarationSha256=sha(return_path),scriptSha256=sha(Path(__file__)),summary=dict(spans=51,sourceSelectedSpans=sum(s['sourceSelectionComplete'] for c in components for s in c['spans']),selectedSourceAssemblies=len(groups),selectedFamilies=sum(len(s['families']) for c in components for s in c['spans']),sourceTrianglesRequiringFinitePartition=len(conflicts)),productionMutation=False,bakeAllowed=False)
    (OUT/'connected-source-family-selections.json').write_text(json.dumps(report,indent=2)+'\n');print(json.dumps(report['summary'],indent=2))


if __name__=='__main__':main()

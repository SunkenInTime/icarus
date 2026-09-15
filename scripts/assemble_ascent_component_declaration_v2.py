"""Combine reviewed Ascent assemblies, explicit corner contracts and finite partitions."""
import json
from pathlib import Path
import numpy as np
from native_compact_wall_profiles import sha
from prepare_ascent_connected_corners import ROOT,OUT


def main():
    selection_path=OUT/'connected-source-family-selections.json';selection=json.loads(selection_path.read_text())
    corners_path=OUT/'column-corner-collapse-declarations.json';corners=json.loads(corners_path.read_text())
    partition_path=OUT/'shared-wall-finite-partition.json';partition=json.loads(partition_path.read_text())
    base_path=OUT/'finite-component-declaration-review.json';base=json.loads(base_path.read_text())
    raw_path=ROOT/'supplemented-v2/world/ascent/geometry.npz';meta=json.loads(raw_path.with_suffix('.json').read_text())
    primary={s['completeSpan']:s for c in base['components'] for s in c['spans']}
    corner_by_span={d['span']:d for d in corners['declarations']}
    partition_by_face={r['sourceFace']:r for r in partition['records']}
    components=[];full_insert_count=0
    for component in selection['components']:
        entries=[]
        for row in component['spans']:
            number=row['completeSpan'];entry=dict(row)
            for family in entry['families']:
                if family['role'] in ['static-insert','open-metal-gate']:
                    ob=meta['objects'][family['sourceObject']]
                    family['reviewedWholeInsertFaces']=list(range(ob['firstFace'],ob['firstFace']+ob['faceCount']))
                    family['wholeInsertPolicy']='The full personally reviewed insert keeps its original Z/UV/material. Clip to its verified finite host along interval before normalization and retain every outside fragment. Gate bars remain separate exact geometry; no profile envelope.'
                    full_insert_count+=1
                family['partitionedSourceFaces']=[]
                for face in family['sourceFaces']:
                    if face not in partition_by_face:continue
                    family['partitionedSourceFaces'].append(dict(sourceFace=face,fragments=[f for f in partition_by_face[face]['fragments'] if f['owner']==number],otherFragmentsRef=dict(file=str(partition_path),sourceFace=face)))
            if number in primary:
                entry['priorExplicitMappings']=primary[number]['families']
            if number in corner_by_span:
                entry['approvedCornerAbstraction']=corner_by_span[number]
            entry['bakeAllowed']=False
            entries.append(entry)
        components.append(dict(component=component['component'],closed=True,spans=entries,joins=component['joins']))
    report=dict(format='icarus-finite-component-declaration-review-v2',map='ascent',components=components,sourceFileSha256=selection['sourceFileSha256'],sourceSelectionSha256=sha(selection_path),squareCornerContractSha256=sha(corners_path),sourcePartitionSha256=sha(partition_path),priorExplicitDeclarationSha256=sha(base_path),scriptSha256=sha(Path(__file__)),summary=dict(authoredSpans=51,selectedSpans=50,selectedAssemblies=41,selectedFamilies=78,fullGeometryInsertFamilies=full_insert_count,partitionedSharedSourceFaces=len(partition['records']),retainedBackingFragments=partition['verification']['retainedBetweenArchFragments'],squareCornerContracts=sum(len(d['cornerContracts']) for d in corners['declarations'])),reviewedSemantics=['Structural wall/arch/column backing groups selected after all43 full source assemblies were personally viewed.','Static window/door geometry and open metal gates retain original height profiles and materials.','Four column corners use explicit source-edge height coverage for square SVG presentation.','Intervening Mid arch and its retained backing wall are separately owned.'],remainingConditions=['Resolve nonplanar boat correspondence at span208, or retain it with an explicit whole-component uncertainty scope.','Compile common source/authored join frames for the complete family graph, including all exact incident bevel edge contracts.','Resolve remaining wall-attached relief ownership using source adjacency and verify all retained-source attachments before accepting a candidate.','Run original source partition, height/material preservation, exact authored stop, cross-family shared-vertex and unchanged-attachment checks before native visual replay.'],productionMutation=False,bakeAllowed=False)
    path=OUT/'finite-component-declaration-review-v2.json';path.write_text(json.dumps(report,indent=2)+'\n');print(json.dumps(report['summary'],indent=2))


if __name__=='__main__':main()

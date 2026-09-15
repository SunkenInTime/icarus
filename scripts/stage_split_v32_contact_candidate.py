"""Stage reviewed V32 contact declarations and freeze their offline compiler."""
import argparse
from copy import deepcopy
import hashlib,json,shutil
from pathlib import Path
import numpy as np

ROOT=Path('E:/IcarusWorldAudit/2026-09-06');REV=ROOT/'tactical-visibility-revision'
BASE='split-wall-family-normalized-candidate-v31-precise-v1'
BASE_BINDINGS='39c28d1a8eaf10d89e13c271e559f6cc1cea96bdb9fadd6039f5fc79437d3bf2'
BASE_PACK='0aa18743a5bda73e484f6cee7280a9f1e84564c9f448073e17fe9261affde5d2'
ROOM='split-vent-room-finite-field-experiment-v6/sealed-held-region-declaration.json'
ROOM_SHA='13df37ccc628601146fbcb194338e599dfc4805ae3dab2ffb927a792822ecc10'
CHAIN='split-upper-vent-chain-field-proposal-v2/held-region-declaration.json'
CHAIN_SHA='cb57e0f3b8dc6348f55a6354a010b26d63c7a56b4cc140a1fc3f0a9ded4fc2ff'
ASITE='split-asite-building-connected-proposal-v6/region-declaration.json'
ASITE_SHA='a3aa0137313322abe7a71e916c1d5f0965aeb6b2b9c00f6eca1609bec97f0448'

def sha(path):return hashlib.sha256(Path(path).read_bytes()).hexdigest()
def read_bound(path,expected):
    assert sha(path)==expected,(str(path),'Hash changed')
    return json.loads(Path(path).read_text())
def stamp(path):return dict(path=str(path),sha256=sha(path))
def boxes_overlap(a,b):return bool((np.maximum(a[:2],b[:2])<=np.minimum(a[2:],b[2:])).all())

def stage(version,asite_gate=None,asite_gate_sha256=None):
    assert version and all(c.isalnum()or c in '-_'for c in version)
    assert (asite_gate is None)==(asite_gate_sha256 is None),'Optional A-site requires its explicit reviewed gate hash'
    basep=REV/BASE/'bindings.json';base=read_bound(basep,BASE_BINDINGS);assert sha(basep.parent/'split.height.bin.gz')==BASE_PACK
    room=read_bound(REV/ROOM,ROOM_SHA);chain=read_bound(REV/CHAIN,CHAIN_SHA)
    evidence=[REV/BASE/'independent-profile-review.json',REV/'root-v31-personal-render-review.json',
        REV/'split-vent-room-finite-field-experiment-v6/independent-room-gate.json',
        REV/'split-upper-vent-chain-field-proposal-v2/independent-chain-gate.json',
        REV/'split-vent-room-raw-partition-v3/partition-review.json',REV/'split-upper-vent-chain-raw-partition-v2/partition-review.json',
        REV/'split-room-upper-chain-standing-rays-v2/contact-and-preservation-review.json',
        REV/'split-upper-vent-chain-contacts-native8x-v1/manifest.json']
    gates=[json.loads(evidence[i].read_text())for i in [2,3]]
    assert [g['declarationSha256']for g in gates]==[ROOM_SHA,CHAIN_SHA]
    assert gates[1]['contact']['changedFrozenHitIndices']==list(range(391,416))
    assert gates[0]['partitionReportSha256']==sha(evidence[4])
    assert gates[1]['partitionReportSha256']==sha(evidence[5])
    assert gates[1]['contactReportSha256']==sha(evidence[6])
    chain_affected=set(np.load(REV/'split-upper-vent-chain-raw-partition-v2/raw-source-fragments.npz')['originalSourceFaces'])
    families=deepcopy(base['families']);old174=next(f for f in families if f['edge']==174)
    assert set(old174['objects']).issubset(room['objects'])
    families=[room if f['edge']==174 else f for f in families];families.append(chain)
    additions=[room,chain];declarations=[REV/ROOM,REV/CHAIN];asite_contract=None;dependency_evidence=[]
    if asite_gate is not None:
        gate=read_bound(asite_gate,asite_gate_sha256);asite=read_bound(REV/ASITE,ASITE_SHA)
        assert gate['passed'] and gate['declaration']['sha256']==ASITE_SHA
        for row in [*gate['evidence'],*gate['currentHelpers'].values()]:
            assert sha(row['path'])==row['sha256'],row['path']
            dependency_evidence.append(row)
        old17=next(f for f in families if f['edge']==17)
        assert gate['stagingContract']['preservedLegacyDeclaration']==old17
        assert gate['stagingContract']['otherPriorFamilyRawOverlap']==0
        assert gate['continuousInterface']['maximumLegacy17FieldErrorSvg']<1e-12
        shared=sorted(set(old17['objects'])&set(asite['objects']));assert shared==[429,5857] and 7107 not in asite['objects']
        raw=np.load(ROOT/'supplemented-v2/world/split/geometry.npz');points,faces=raw['points'],raw['faces']
        meta=json.loads((ROOT/'supplemented-v2/world/split/geometry.json').read_text())
        projection=np.array(json.loads((ROOT/'tactical-alignment-sides-v1/split.json').read_text())['nativeToAttackSvg'])
        bounds=[]
        for obj in shared:
            item=meta['objects'][obj];ids=np.arange(item['firstFace'],item['firstFace']+item['faceCount'])
            assert set(ids).issubset(asite['reviewedSourceFaces'])
            xy=points[faces[ids]][:,:,:2]@projection[:,:2].T+projection[:,2]
            assert(xy>=asite['box'][:2]).all()and(xy<=asite['box'][2:]).all()
            bounds.append(dict(object=obj,allRawParents=len(ids),boundsSvg=[xy.min((0,1)).tolist(),xy.max((0,1)).tolist()]))
        index=next(i for i,f in enumerate(families)if f['edge']==17);families.insert(index,asite)
        assert families[index+1]==old17
        additions.append(asite);declarations.append(REV/ASITE);evidence.append(Path(asite_gate))
        asite_contract=dict(newFamily=200018,beforeUnchangedFamily=17,completeSupersededSourceObjects=bounds,
            preserved7107=True,legacy17DeclarationLiteral=True,
            compilerBehavior='Each family takes only its box-clipped inside polygon. Exterior fragments remain in pieces for later families; whole raw parents are not consumed.',
            reviewGate=stamp(asite_gate))
    assert len({f['edge']for f in families})==len(families)
    unchanged=[]
    for prior in base['families']:
        if prior['edge']==174:continue
        assert next(f for f in families if f['edge']==prior['edge'])==prior
        unchanged.append(prior['edge'])
    assert {200105,200140,200190,200208,200209,108,17}.issubset(unchanged)
    overlaps=[]
    for added in additions:
        for prior in base['families']:
            if prior['edge']==174:continue
            objects=sorted(set(added['objects'])&set(prior['objects']))
            if not objects:continue
            overlap=boxes_overlap(added['box'],prior['box'])
            original=set(prior.get('originalSourceFaces',[]));reviewed=set(added['reviewedSourceFaces'])
            row=dict(newFamily=added['edge'],existingFamily=prior['edge'],sharedObjects=objects,
                sourceBoxesOverlap=overlap,existingRawParentIntersection=sorted(original&reviewed),
                newPriority=families.index(added)<next(i for i,f in enumerate(families)if f['edge']==prior['edge']))
            if added['edge']==200172:
                row['actuallyIntersectingRawParentIntersection']=sorted(original&chain_affected)
                assert not row['actuallyIntersectingRawParentIntersection']
            if overlap:
                assert(added['edge'],prior['edge'])==(200018,17)and row['newPriority'],'Unreviewed source/domain priority overlap'
            else:assert(added['edge'],prior['edge'])in[(200172,97),(200172,10099)]
            overlaps.append(row)
    output=REV/f'split-connected-contact-stage-{version}';output.mkdir(exist_ok=False)
    declared=output/'family-declarations.json';declared.write_text(json.dumps(families,indent=2)+'\n')
    compiler=output/'compiler';compiler.mkdir();compiler_rows=[]
    for source in sorted(Path('scripts').glob('*.py')):
        destination=compiler/source.name;shutil.copyfile(source,destination);compiler_rows.append(stamp(destination))
    prior_compiler=REV/'split-connected-contact-stage-v31-precise-v1/compiler';core=[]
    for name in ['build_split_normalized_wall_families.py','finite_region_cells.py','precise_region_containment.py','native_region_source.py','tactical_pack_writer.py','authored_region_cells.py']:
        assert sha(compiler/name)==sha(prior_compiler/name),('Compiler changed since V31',name)
        core.append(dict(file=name,sha256=sha(compiler/name),literalV31Compiler=True))
    copied_evidence=output/'gate-evidence';copied_evidence.mkdir();evidence_rows=[]
    for index,path in enumerate(evidence):
        target=copied_evidence/f'{index:02d}-{path.name}';shutil.copyfile(path,target)
        row=stamp(path);row['frozenCopy']=str(target);assert sha(target)==row['sha256'];evidence_rows.append(row)
    inputs=[ROOT/'supplemented-v2/world/split/geometry.npz',ROOT/'supplemented-v2/world/split/geometry.json',
        REV/'global-ground-complete-v2/split/split.height.bin.gz',REV/'global-ground-complete-v2/split/correspondence.npz',
        REV/'full-height-input-v1/split/source-correspondence.npz',REV/'display-warps-v1/split.display-warp.json.gz']
    manifest=dict(version=version,baseBindings=stamp(basep),basePack=stamp(basep.parent/'split.height.bin.gz'),
        reviewedDeclarations=[stamp(p)for p in declarations],evidenceFiles=evidence_rows,dependencyEvidence=dependency_evidence,checkedInputs=[stamp(p)for p in inputs],
        declarationFile=str(declared),declarationSha256=sha(declared),compilerFiles=compiler_rows,coreCompilerPreservation=core,
        candidateOutput=str(REV/f'split-wall-family-normalized-candidate-{version}'),
        unchangedFamilyEdges=unchanged,removedFamilyEdges=[174],addedFamilyEdges=[f['edge']for f in additions],
        sourceOwnership=overlaps,asitePriorityContract=asite_contract,
        floorPolicy='Existing provisional ground field. Final tactical receiver floor policy remains separate.',
        status='Staged only. No bake started and no application assets changed.',productionMutation=False)
    (output/'stage.json').write_text(json.dumps(manifest,indent=2)+'\n')
    summary=dict(stage=str(output),families=len(families),unchangedFamilies=len(unchanged),removed=[174],added=manifest['addedFamilyEdges'],
        preservedV31Fixes=[200105,200140,200190,200208,200209],existing108Preserved=True,legacy17Preserved=True,
        compilerFiles=len(compiler_rows),evidenceFiles=len(evidence_rows),ownership=overlaps,asiteIncluded=asite_gate is not None,
        candidateOutput=manifest['candidateOutput'],bakeStarted=False,stageManifestSha256=sha(output/'stage.json'))
    (output/'stage-only-summary.json').write_text(json.dumps(summary,indent=2)+'\n');print(json.dumps(summary,indent=2));return output

if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--version',default='v32-vent-only-v1');p.add_argument('--asite-gate',type=Path);p.add_argument('--asite-gate-sha256');args=p.parse_args();stage(args.version,args.asite_gate,args.asite_gate_sha256)

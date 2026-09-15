"""Independent held-chain source, topology and standing-contact evidence bundle."""
import gzip,json,shutil
from pathlib import Path
import numpy as np
from tactical_alignment_composite import explicit_warp
from verify_region_mapping import verify_region_topology,verify_rank_one_declarations
from lift_reviewed_wall_source_heights import sha

ROOT=Path('E:/IcarusWorldAudit/2026-09-06');REV=ROOT/'tactical-visibility-revision';out=REV/'split-upper-vent-chain-field-proposal-v2'
fp=out/'held-region-declaration.json';f=json.loads(fp.read_text());wp=REV/'display-warps-v1/split.display-warp.json.gz';w=json.loads(gzip.decompress(wp.read_bytes()))
m=np.column_stack((w['projection']['axisU'],w['projection']['axisV']));o=np.array(w['projection']['origin']);ws=np.array(w['sourceNativeMeters']).reshape(-1,2)@m.T+o;wt=np.array(w['targetAttackSvg']).reshape(-1,2);wc=np.array(w['triangles']).reshape(-1,3)
forward=explicit_warp(ws,wt-ws,wc);topology=verify_region_topology(f,forward);rank=verify_rank_one_declarations(f)
partp=REV/'split-upper-vent-chain-raw-partition-v2/partition-review.json';part=json.loads(partp.read_text());frp=partp.parent/'raw-source-fragments.npz';fr=np.load(frp)
rawp=ROOT/'supplemented-v2/world/split/geometry.npz';raw=np.load(rawp);parents=fr['sourceFaces'];bary=fr['barycentrics'];source=raw['points'][raw['faces'][parents]];expected=np.einsum('nij,njk->nik',bary,source)
zerr=float(abs(expected[:,:,2]-fr['trianglesNativeSourceZ'][:,:,2]).max());uv_expected=np.einsum('nij,njk->nik',bary,raw['uvs'][parents]);uverr=float(abs(uv_expected-fr['uvs']).max());outside=fr['regionCells']<0
outsideerr=float(abs(expected[outside]-fr['trianglesNativeSourceZ'][outside]).max(initial=0));assert zerr<1e-12 and uverr<1e-12 and outsideerr<1e-12
rayp=REV/'split-room-upper-chain-standing-rays-v2/composed-rays.json';rays=json.loads(rayp.read_text());cp=rayp.parent/'contact-and-preservation-review.json';contact=json.loads(cp.read_text())
assert contact['changedFrozenHitIndices']==list(range(391,416))
assert all(x['maximumContinuousCoordinateDisagreementSvg']<2e-13 for x in contact['continuousRoom172Correspondence'])
for edge in [169,170,171,172]:
    group=contact['grid'][str(edge)];assert not group['clear']
    for hit in group['hits'].values():assert max(map(abs,hit['normalErrorRangeSvg']))<2e-13
paired=[]
for edge in [169,170,171,172]:
    rows=[r for r in rays['records']if r['gridProbe']and r['gridProbe']['edge']==edge]
    paired.append(dict(edge=edge,rays=len(rows),maximumLiteralAttackBoundaryDistanceSvg=max(r['after']['receiverBoundaryDistanceSvg'][0]for r in rows),maximumLiteralDefenseBoundaryDistanceSvg=max(r['after']['receiverBoundaryDistanceSvg'][1]for r in rows)))
snapshot=out/'source-snapshot';snapshot.mkdir(exist_ok=False)
files=['propose_split_upper_vent_chain_field.py','partition_split_upper_vent_chain_source.py','review_split_upper_vent_chain_field.py','review_split_upper_vent_chain_source.py','render_split_upper_chain_members.py','prepare_split_room_chain_ray_audit.py','audit_split_room_upper_chain_composed_rays_v2.py','check_split_room_upper_chain_rays.py','prepare_split_upper_chain_contact_render.py','render_split_upper_chain_contacts.py','gate_split_upper_vent_chain_v2.py','propose_split_vent_room_finite_field.py','extend_split_vent_room_wall_membership.py','partition_split_vent_room_source.py','audit_split_vent_room_composed_rays.py','compare_split_vent_room_membership_rays.py','gate_split_vent_room_v6.py','render_split_vent_room_receiver_contacts.py']
for name in files:shutil.copyfile(Path('scripts')/name,snapshot/name)
report=dict(declarationSha256=sha(fp),scriptSha256=sha(Path(__file__)),topology=topology,scalarCells=len(rank),constantCells=len(f['declaredConstantPointCells']),
    partitionReportSha256=sha(partp),partition=part,fragmentSha256=sha(frp),maximumOriginalZErrorMeters=zerr,maximumUvError=uverr,
    exteriorSourceXYZErrorMeters=outsideerr,exteriorTriangles=int(outside.sum()),standingRaysSha256=sha(rayp),contactReportSha256=sha(cp),contact=contact,literalPairedArt=paired,
    reviewedImages=dict(sourceMembers='split-upper-vent-chain-source-members-v1: all7 PNGs',sourceProfiles='split-upper-vent-chain-field-proposal-v2: all4 six-height PNGs',actualSvg='split-upper-vent-chain-contacts-native8x-v1: all20 PNGs'),
    sourceSnapshot=[dict(file=name,sha256=sha(snapshot/name))for name in files],
    limits=['Standing horizontal source sections only; final tactical receiver floor policy is separate.',
        'Source5927 opposite upper65/66 doorway/header and high ceiling/cornice profiles remain preserved; this gate does not certify their exact SVG contact.',
        'Literal defense169 differs0.0008 SVG and defense171 differs0.0002 SVG from canonical flip; SVG files are unchanged.',
        'No compiler pack, application cone, gameplay capture, or performance result is claimed.'],
    next=['Root review of the20 both-side contacts and7 mounted source members.',
        'Stage200174 V6 and200172 V2 alongside untouchedV30 pipe and other approved corrections.',
        'Run complete compiler/source partition/original-height composition checks, preserving distant97/10099 and accepted contacts.',
        'Apply the separate tactical receiver-layer policy and inspect application cone boundaries before promotion.'],
    status='Held proposal with source and standing-contact evidence. Root controls staging; no production mutation.')
(out/'independent-chain-gate.json').write_text(json.dumps(report,indent=2)+'\n')
print(json.dumps(dict(output=str(out/'independent-chain-gate.json'),z=zerr,uv=uverr,exteriorXYZ=outsideerr,paired=paired)))

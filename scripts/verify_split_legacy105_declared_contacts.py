"""Continuous contact and unchanged-ownership boundary gates for105 proposal."""
import gzip
import json
from pathlib import Path

import numpy as np
import shapely

from declare_split_legacy105_connected_region import ROOT, REV, sha
from tactical_alignment_composite import explicit_warp
from verify_region_contact import segment_cells
from verify_region_mapping import verify_rank_one_declarations


def interval_values(data,start,end,rank):
    source,target,cells,segment,_=data;tri=source[cells]
    inverse=np.linalg.inv(np.stack((tri[:,1]-tri[:,0],tri[:,2]-tri[:,0]),axis=2))
    p=segment[0]+np.array([start,(start+end)/2,end])[:,None]*(segment[1]-segment[0])
    uv=np.einsum('nij,nkj->nki',inverse,p[None]-tri[:,:1]);weights=np.concatenate((1-uv.sum(2,keepdims=True),uv),axis=2)
    covering=np.flatnonzero(weights.min((1,2))>=-1e-9)
    assert len(covering),'Continuous source interval lacks a containing cell'
    values=np.einsum('nij,njk->nik',weights[covering],target[cells[covering]])
    for row,cell in enumerate(covering):
        if int(cell) in rank:
            entry=rank[int(cell)];a,b=entry['endpoints'];parameter=weights[cell]@entry['parameters'];values[row]=a+parameter[:,None]*(b-a)
    return p,values[:,[0,2]]


def wall_gate(family,segment,authored):
    data=segment_cells(family,segment);rank=verify_rank_one_declarations(family);a,b=np.array(authored);t=(b-a)/np.linalg.norm(b-a);n=np.array([-t[1],t[0]])
    normal=0.;along=[];mapped=[]
    for low,high in zip(data[-1][:-1],data[-1][1:]):
        _,v=interval_values(data,low,high,rank);normal=max(normal,float(abs((v-a)@n).max()));mapped.extend(v.reshape(-1,2));along.extend(((v-a)@t).reshape(-1))
    assert normal<1e-7
    return dict(sourceSegmentSvg=segment,authoredSegmentSvg=authored,affineIntervals=len(data[-1])-1,maximumNormalErrorSvg=normal,
        mappedAlongRangeSvg=[float(min(along)),float(max(along))],continuousNormalContact=True,
        heightScope='Only original retained source faces and their individual Z/UV profiles; this is not a height extrusion.')


def main():
    out=REV/'split-legacy105-connected-region-proposal-v6';path=out/'combined-declarations.json';families=json.loads(path.read_text());main_family,bottom=families
    wp=REV/'display-warps-v1/split.display-warp.json.gz';w=json.loads(gzip.decompress(wp.read_bytes()));matrix=np.column_stack((w['projection']['axisU'],w['projection']['axisV']));origin=np.array(w['projection']['origin'])
    ws=np.array(w['sourceNativeMeters']).reshape(-1,2)@matrix.T+origin;wt=np.array(w['targetAttackSvg']).reshape(-1,2);wc=np.array(w['triangles']).reshape(-1,3);forward=explicit_warp(ws,wt-ws,wc)
    constraints=[
        (103,main_family,[[279.28622987276356,280.8797487438403],[279.28622987276356,288.6989892960074]],[[279.074,281.157],[279.074,288.068]]),
        (104,main_family,[[279.28622987276356,280.8797487438403],[291.0197140465251,280.8797487438403]],[[279.074,281.157],[292.365,281.157]]),
        (105,main_family,[[291.0197140465251,280.8797487438403],[291.0197140465251,312.1567706085799]],[[292.365,281.157],[292.365,310.928]]),
        (106,main_family,[[291.0197140465251,312.1567706085799],[314.51621214924637,312.1567706085799]],[[292.365,310.928],[314.89839756052123,310.928]]),
        (139,main_family,[[279.29035753173747,304.33747040034166],[279.29068798942876,327.7951324007719]],[[279.074,304.549],[279.074,327.94]]),
        (140,main_family,[[279.29068798942876,327.7951324007719],[314.51621214924637,327.7951324007719]],[[279.074,327.94],[314.51621214924637,327.94]]),
        (140,bottom,[[314.51621214924637,327.7951398577808],[371.1813963034822,327.7951398577808]],[[314.51621214924637,327.94],[371.1813963034822,327.94]]),
    ]
    contacts=[]
    for edge,family,source_segment,authored in constraints:
        contacts.append(dict(edge=edge,region=family['edge'],**wall_gate(family,source_segment,authored)))
    # The lower partial owner begins where both the new field and all previous
    # owners are physical identity. Split at every declared and W cell edge.
    seam=[[314.5,320.],[381.14,320.]];data=segment_cells(main_family,seam);rank=verify_rank_one_declarations(main_family)
    warp_family=dict(sourceVerticesSvg=ws.tolist(),targetVerticesSvg=wt.tolist(),triangles=wc.tolist());warp_data=segment_cells(warp_family,seam)
    times=np.unique(np.r_[data[-1],warp_data[-1]]);identity_error=0.
    for low,high in zip(times[:-1],times[1:]):
        p,values=interval_values(data,low,high,rank);expected=forward.apply(p[[0,2]])
        identity_error=max(identity_error,float(np.linalg.norm(values-expected,axis=2).max()))
    assert identity_error<1e-7
    for key in ['sourceVerticesSvg','targetVerticesSvg','triangles','declaredRankOneMappings']:
        assert main_family[key]==bottom[key]
    field=explicit_warp(np.array(main_family['sourceVerticesSvg']),np.array(main_family['targetVerticesSvg'])-np.array(main_family['sourceVerticesSvg']),np.array(main_family['triangles']))
    pair=np.array([[314.51621214924637,327.7951324007719],[314.51621214924637,327.7951398577808]])
    shared=field.apply(pair);assert np.max(np.linalg.norm(shared-[314.51621214924637,327.94],axis=1))<1e-7
    old=json.loads((REV/'split-wall-family-normalized-candidate-v29/bindings.json').read_text())
    old_owners=[dict(edge=f['edge'],sourceBox=f['box']) for f in old['families'] if f['edge'] in [106,107]]
    assert max(r['sourceBox'][3] for r in old_owners)<320
    prior=json.loads((REV/'split-legacy105-connected-region-proposal-v2/region-declaration.json').read_text())
    prior_field=explicit_warp(np.array(prior['sourceVerticesSvg']),np.array(prior['targetVerticesSvg'])-np.array(prior['sourceVerticesSvg']),np.array(prior['triangles']))
    top_corners=np.array([[279.28622987276356,280.8797487438403],[279.28622987276356,288.6989892960074],[291.0197140465251,280.8797487438403],[291.0197140465251,312.1567706085799],[314.51621214924637,312.1567706085799]])
    differences=np.linalg.norm(field.apply(top_corners)-prior_field.apply(top_corners),axis=1)
    report=dict(combinedDeclarationsSha256=sha(path),scriptSha256=sha(Path(__file__)),contactConstraints=contacts,
        partialOwnershipBoundary=dict(sourceSegmentSvg=seam,affineIntervals=len(times)-1,maximumPhysicalIdentityErrorSvg=identity_error,priorNormalizedOwners=old_owners,
            reasoning='Existing106/107 source boxes end at or before314.5, so the sourceY320 cut lies in their unchanged outside fragments. Both new owners use identical field vertices, cells and scalar declarations; the field equals displayW continuously on this cut.'),
        bottomNearCoincidentJoin=dict(sourcePointsSvg=pair.tolist(),sourceSeparationSvg=float(np.linalg.norm(pair[1]-pair[0])),targetPointsSvg=shared.tolist(),targetCoincidenceErrorSvg=float(np.linalg.norm(shared[1]-shared[0]))),
        priorTopJoinControl=dict(priorDeclarationSha256=sha(REV/'split-legacy105-connected-region-proposal-v2/region-declaration.json'),sourcePointsSvg=top_corners.tolist(),maximumDisplayedJoinChangeSvg=float(differences.max()),
            limitation='The full old field is not unchanged: continuous generator/left-depth bands and lower joins were revised. Only these endpoint contacts and reverified normal constraints may reuse prior acceptance; individual height/profile and ray proofs still require the new candidate.'),
        sourceHeightRule='The declarations contain XY coordinates only. The native constructor must carry original-source barycentrics and interpolate original Z/UV unchanged; the packed proof is still required before rendering acceptance.')
    (out/'continuous-contact-review.json').write_text(json.dumps(report,indent=2)+'\n')
    print(json.dumps(dict(contacts=len(contacts),maximumNormalError=max(x['maximumNormalErrorSvg'] for x in contacts),seamIdentityError=identity_error,topJoinChange=float(differences.max()))))


if __name__=='__main__':main()

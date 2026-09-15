"""Measure real before/after cone pixels at source-confirmed straight-wall hits.

Corner hits, range-limited rays and unmatched source hits are listed separately.
This checks the captured V31 contacts only, not all walls or floor semantics.
"""
import gzip
import json
from pathlib import Path

import numpy as np
from PIL import Image

from audit_wall_contact_pixels import PhysicalGeometry, pixel_gap
from native_reference_cast import NativeReferenceModel
from tactical_alignment_audit import vector_lines
from tactical_alignment_composite import explicit_warp
from probe_real_receiver_room_controls import sha


def main():
    r=Path('E:/IcarusWorldAudit/2026-09-06/tactical-visibility-revision')
    out=r/'split105-native-pixel-contact-review-v1';out.mkdir(exist_ok=False)
    folders=[r/'105-contact-v30-baseline-v1',r/'105-contact-v31-candidate-v1']
    manifests=[json.loads((f/'manifest.json').read_bytes()) for f in folders]
    before={ (c['id'],c['side']):c for c in manifests[0]['cases'] }
    pack=r/'split-wall-family-normalized-candidate-v31-precise-v1/split.height.bin.gz'
    assert sha(pack)==manifests[1]['declaredCandidatePackSha256']
    wp=Path(manifests[1]['displayWarpFile']);w=json.loads(gzip.decompress(wp.read_bytes()))
    matrix=np.column_stack([w['projection']['axisU'],w['projection']['axisV']]);origin=np.array(w['projection']['origin'])
    ws=np.array(w['sourceNativeMeters']).reshape(-1,2)@matrix.T+origin
    wt=np.array(w['targetAttackSvg']).reshape(-1,2)
    warp=explicit_warp(ws,wt-ws,np.array(w['triangles']).reshape(-1,3))
    art=vector_lines(Path('assets/maps/split_map.svg'))
    model=NativeReferenceModel(pack,r/'native-tactical-rays-build/Release/tactical_reference_cast.dll')
    inks={};rows=[];skipped=[]
    for row in manifests[1]['cases']:
        q=np.asarray(row['query']);old=before[(row['id'],row['side'])]
        assert row['query']==old['query']
        hit=model.cast(q[:3],q[:3]+np.r_[q[3:5]/np.linalg.norm(q[3:5])*q[5],0.])
        if hit is None:
            skipped.append(dict(id=row['id'],side=row['side'],reason='No center-ray source hit before range'));continue
        contact=warp.apply(np.asarray(hit['point'][:2])@matrix.T+origin)
        matched=[]
        for edge,line in enumerate(art):
            if len(line)!=2:continue
            axis=int(np.argmax(abs(line[1]-line[0])));normal=1-axis
            if abs(line[1,normal]-line[0,normal])>1e-10:continue
            error=abs(contact[normal]-line[0,normal])
            if error<=1e-5 and line[:,axis].min()<=contact[axis]<=line[:,axis].max():
                margin=min(contact[axis]-line[:,axis].min(),line[:,axis].max()-contact[axis])
                matched.append((margin,edge,axis,normal,line))
        matched.sort(key=lambda x:-x[0])
        if not matched or matched[0][0]<2.:
            skipped.append(dict(id=row['id'],side=row['side'],reason='Corner or source hit without a two-SVG-unit straight-wall margin',
                                contactSvg=contact.tolist(),sourceHit=hit));continue
        _,edge,along,normal,line=matched[0]
        eye=warp.apply(q[:2]@matrix.T+origin)
        inward=1 if eye[normal]>contact[normal] else -1
        if row['side']=='defense':
            contact=np.array(w['attackToDefenseSvg']['origin'])-contact;inward=-inward
        meshpath=Path(row['prefix']+'-shadow.f32')
        assert sha(meshpath)==row['meshSha256']
        geometry=PhysicalGeometry(w,row,np.frombuffer(meshpath.read_bytes(),dtype='<f4'))
        for scale in [2,8]:
            crops=[next(c for c in source['rasterRegions'] if c['name']=='focus' and c['kind']=='visibility' and c['scale']==scale)
                   for source in [old,row]]
            assert crops[0]['pixelRect']==crops[1]['pixelRect']
            rect=np.array(crops[1]['pixelRect']);start=rect[:2]
            lo=int(np.ceil((contact[along]-.5)*scale-.5));hi=int(np.floor((contact[along]+.5)*scale-.5))
            columns=np.arange(lo,hi+1)
            xy=np.tile(contact,(len(columns),1));xy[:,along]=(columns+.5)/scale
            valid=geometry.in_frustum(xy,margin=False)
            measurements=[]
            for folder,source,crop in zip(folders,[old,row],crops):
                key=(str(folder),row['side'],scale)
                if key not in inks:
                    inks[key]=np.array(Image.open(folder/f"{row['side']}-{scale}x-ink.png").convert('RGBA'))[:,:,3]
                ink=inks[key][rect[1]:rect[3],rect[0]:rect[2]]
                vis=np.array(Image.open(crop['path']).convert('RGBA'))[:,:,3]
                assert ink.shape==vis.shape
                if normal==0:ink,vis=ink.T,vis.T
                wall=contact[normal]*scale-start[normal]
                ys=np.arange(max(0,int(wall-3*scale)),min(ink.shape[0],int(wall+3*scale)+1))
                profiles=[]
                for column,inside in zip(columns,valid):
                    local=column-start[along]
                    if inside and 0<=local<ink.shape[1]:
                        gap=pixel_gap(ink[:,local],vis[:,local],ys,wall,inward,scale)
                        profiles.append(dict(globalColumn=int(column),measurement=gap))
                measurements.append(dict(version='V31' if source is row else 'V30',profiles=profiles,
                    visibilitySha256=sha(Path(crop['path']))))
            rows.append(dict(id=row['id'],side=row['side'],scale=scale,edge=edge,
                contactSvg=contact.tolist(),normalInward=inward,measurements=measurements))
    summaries=[]
    for version in ['V30','V31']:
        measurements=[p['measurement'] for row in rows for m in row['measurements'] if m['version']==version for p in m['profiles']]
        usable=[m for m in measurements if m is not None and m['blankPixels'] is not None]
        summaries.append(dict(version=version,offeredProfiles=len(measurements),measuredProfiles=len(usable),
            missingInkOrCone=len(measurements)-len(usable),
            profilesWithBlankPixels=sum(m['blankPixels']>0 for m in usable),
            maximumBlankPixels=max((m['blankPixels'] for m in usable),default=None),
            failedCoverageContacts=sum(not m['coverageContactPassed'] for m in usable)))
    report=dict(scope=__doc__,summaries=summaries,records=rows,skipped=skipped,
        sourceManifests=[dict(path=str(f/'manifest.json'),sha256=sha(f/'manifest.json')) for f in folders],
        scriptSha256=sha(Path(__file__)),productionPromotion=False,
        limitations=['Center-ray matched source contacts define these straight-wall tests. This does not infer blocker roles from SVG ink.',
            'Corner controls require separate geometry and visual review.',
            'Finite raster profiles at 2x and8x; not an exhaustive continuous wall or gameplay proof.'])
    (out/'report.json').write_text(json.dumps(report,indent=2)+'\n')
    print(json.dumps(dict(summaries=summaries,caseScales=len(rows),skippedSideCases=len(skipped))))


if __name__=='__main__':main()

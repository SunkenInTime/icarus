"""Name-independent wall-contact candidates, with incomplete evidence explicit.

This only inventories orientation-matched first contacts. It never assigns a
wall role, fills absent profiles, or treats a median source plane as sufficient.
"""
import argparse
import csv
import hashlib
import json
from pathlib import Path
import numpy as np

ROOT=Path('E:/IcarusWorldAudit/2026-09-06')

def run(coverage_path,out):
    data=json.loads(coverage_path.read_text());name=data['map']
    folder=ROOT/'supplemented-v2/world'/name
    meta=json.loads((folder/'geometry.json').read_text());raw=np.load(folder/'geometry.npz');p,f=raw['points'],raw['faces']
    affine=np.array(json.loads((ROOT/f'tactical-alignment-sides-v1/{name}.json').read_text())['nativeToAttackSvg'])
    rows=[]; summaries=[]
    for edge in data['records']:
        line=np.array(edge['lineSvg']);tangent=line[1]-line[0];length=np.linalg.norm(tangent);tangent/=length
        normal=np.array([-tangent[1],tangent[0]])
        counts={};classified=[]
        for sample in edge['samples']:
            row=dict(sample)
            fid=sample.get('originalSourceFace')
            if fid is None:status='no source contact'
            else:
                tri=p[f[fid]].copy();tri[:,:2]=tri[:,:2]@affine[:,:2].T+affine[:,2]
                n=np.cross(tri[1]-tri[0],tri[2]-tri[0]);xylen=np.linalg.norm(n[:2]);nlen=np.linalg.norm(n)
                alignment=abs(float(n[:2]@normal/xylen)) if xylen else 0
                row['sourceNormalAlignment']=alignment
                if not nlen or abs(n[2])/nlen>.025:status='source face is not vertical'
                elif alignment<np.cos(np.deg2rad(3)):status='intervening or corner-oriented face'
                elif abs(sample.get('inwardGapSvg',1e9))>3:status='distant parallel face'
                else:status='near parallel first contact'
            row['classification']=status;classified.append(row);counts[status]=counts.get(status,0)+1
        summaries.append(dict(edge=edge['svgEdge'],lineSvg=edge['lineSvg'],classificationCounts=counts))
        for height in sorted(set(s['relativeEyeHeightMeters'] for s in classified if 'relativeEyeHeightMeters' in s)):
            samples=sorted((s for s in classified if s.get('relativeEyeHeightMeters')==height),key=lambda s:s['alongSvg'])
            runs=[];run=[]
            for sample in samples:
                if sample['classification']=='near parallel first contact':run.append(sample)
                elif run:runs.append(run);run=[]
            if run:runs.append(run)
            for run in runs:
                extent=run[-1]['alongSvg']-run[0]['alongSvg']
                if extent<2:continue
                offsets=np.array([s['inwardGapSvg'] for s in run]);objects=sorted(set(s['sourceObjectIndex'] for s in run))
                rows.append(dict(edge=edge['svgEdge'],lineSvg=edge['lineSvg'],relativeEyeHeightMeters=height,alongSvg=[run[0]['alongSvg'],run[-1]['alongSvg']],sampledExtentSvg=extent,samples=len(run),minimumGapSvg=float(offsets.min()),medianGapSvg=float(np.median(offsets)),maximumGapSvg=float(offsets.max()),planeSpreadSvg=float(np.ptp(offsets)),maximumAbsoluteGapSvg=float(abs(offsets).max()),sourceObjectIndices=objects,sourceObjects=[dict(index=i,**meta['objects'][i]) for i in objects],originalSourceFaces=sorted(set(s['originalSourceFace'] for s in run)),coversBothSampledEndpoints=run[0] is samples[0] and run[-1] is samples[-1],evidenceLimit='Sampled first contacts only. Hidden parallel relief, intervening props, openings between samples, and complete corner ownership require separate source-profile review. No normalization is authorized by this row.'))
    rows.sort(key=lambda r:r['maximumAbsoluteGapSvg']*r['sampledExtentSvg'],reverse=True)
    result=dict(map=name,coverageFile=str(coverage_path),coverageSha256=hashlib.sha256(coverage_path.read_bytes()).hexdigest(),sourceGeometrySha256=data['sourceGeometrySha256'],artSha256=data['artSha256'],objectNamesUsedForClassification=False,assumedGameRule=False,classificationToleranceDegrees=3,nearContactBoundSvg=3,scope='Prioritize continuous sampled source planes against authored lines. A proposal queue, not proof of wall semantics or complete surface-family coverage.',spans=rows,edges=summaries)
    out.mkdir(exist_ok=True);(out/'inventory.json').write_text(json.dumps(result,indent=2))
    with (out/'review-queue.csv').open('w',newline='') as stream:
        keys=['edge','relativeEyeHeightMeters','alongSvg','sampledExtentSvg','minimumGapSvg','maximumGapSvg','planeSpreadSvg','sourceObjectIndices','coversBothSampledEndpoints']
        writer=csv.DictWriter(stream,fieldnames=keys);writer.writeheader();writer.writerows({k:r[k] for k in keys} for r in rows)
    print(json.dumps(dict(map=name,spans=len(rows),edges=len(summaries),output=str(out))))

if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('coverage',type=Path);parser.add_argument('output',type=Path);args=parser.parse_args();run(args.coverage,args.output)

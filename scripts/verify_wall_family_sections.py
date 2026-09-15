"""Check continuous perpendicular coverage of bounded wall candidate sections."""
import argparse
import json
import numpy as np
from shapely import LineString,union_all,get_parts
from audit_all_map_wall_span_coverage import REV,sha
from native_reference_cast import NativeReferenceModel
from review_map_wall_families import CHOICES

def main(name,include_relief=False):
    folder=REV/f'{name}-wall-family-review-v1';path=REV/f'global-ground-complete-v2/{name}/{name}.height.bin.gz';model=NativeReferenceModel(path,REV/'native-tactical-rays-build/Release/tactical_reference_cast.dll')
    c2f=np.load(path.parent/'correspondence.npz')['sourceFaces'];f2o=np.load(REV/f'full-height-input-v1/{name}/source-correspondence.npz')['sourceFaces'];c2o=f2o[c2f]
    for sid in CHOICES[name]:
        packet_path=folder/f'span-{sid}.json';r=json.loads(packet_path.read_text());context=np.load(folder/f'span-{sid}-source-context.npz')
        tri=context['vertices'];p=r['sourcePlane'];axis=np.array(p['axisXY']);normal=np.array(p['normalXY']);center=np.array(p['originXY']);low,high=p['alongBoundsMeters']
        rawcross=np.cross(tri[:,1]-tri[:,0],tri[:,2]-tri[:,0]);rawcross/=np.maximum(np.linalg.norm(rawcross,axis=1)[:,None],1e-30)
        v=(tri[:,:,:2]-center)@normal
        # A face-level review inventory, not an automatic wall ownership rule.
        selected=(context['sourceObjects']==r['primaryInstanceIndex'])&(np.abs(rawcross[:,2])<=.025)&(np.abs(rawcross[:,:2]@normal)>=.999)&(np.max(np.abs(v-p['normalOffsetMeters']),axis=1)<=.03)
        if include_relief:
            selected=(context['sourceObjects']==r['primaryInstanceIndex'])&(np.max(np.abs(v-p['normalOffsetMeters']),axis=1)<=.03)
        original=np.unique(context['sourceFaces'][selected]);control=np.flatnonzero(np.isin(c2o,original));tt=model.arrays['vertices'][model.arrays['faces'][control]];uu=(tt[:,:,:2]-center)@axis
        sections=[]
        for h in [.75,1.75,2.75]:
            spans=[];bound=[]
            for face,xyz,u in zip(control,tt,uu):
                z=xyz[:,2]-h;values=[]
                for j in range(3):
                    k=(j+1)%3
                    if z[j]==0:values.append(float(u[j]))
                    if z[j]*z[k]<0:values.append(float(u[j]+(u[k]-u[j])*(-z[j])/(z[k]-z[j])))
                if not values:continue
                a=max(low,min(values));b=min(high,max(values))
                if b<a:continue
                spans.append(LineString([(a,0),(b,0)]));bound.append(dict(controlFace=int(face),fullPackFace=int(c2f[face]),originalSourceFace=int(c2o[face]),alongSourceMeters=[a,b]))
            reference=LineString([(low,0),(high,0)]);combined=union_all(spans);missing=reference.difference(combined)
            gap_probes=[];example=next(row for row in r['originalSamples'] if 'probeNativeXY' in row);direction=np.diff(np.array(example['probeNativeXY']),axis=0)[0];sign=np.sign(direction@normal)
            for gap in get_parts(missing):
                if gap.length<1e-8:continue
                along=gap.interpolate(.5,normalized=True).x;point=center+axis*along
                start=np.r_[point-normal*sign*2,h];end=np.r_[point+normal*sign*2,h];hit=model.cast(start,end)
                if hit is not None:
                    face=int(hit['face']);hit.update(controlFace=face,fullPackFace=int(c2f[face]),originalSourceFace=int(c2o[face]),normalOffsetMeters=float((np.array(hit['point'][:2])-center)@normal))
                gap_probes.append(dict(alongSourceMeters=along,gapLengthMeters=float(gap.length),hit=hit))
            sections.append(dict(relativeEyeHeightMeters=h,coveredLengthMeters=float(reference.length-missing.length),totalLengthMeters=float(reference.length),uncoveredLengthMeters=float(missing.length),missingWkt=missing.wkt,sections=bound,uncoveredMidpointProbes=gap_probes))
        result=dict(map=name,span=sid,packetSha256=sha(packet_path),sourcePackSha256=sha(path),scriptSha256=sha(__import__('pathlib').Path(__file__)),
            originalSourceFaceIds=original.tolist(),controlFaceIds=control.tolist(),fullPackFaceIds=np.unique(c2f[control]).tolist(),sections=sections,
            scope='Exact triangle cross-sections projected along the near-plane primary wall family. Proves perpendicular standing coverage only inside the sampled along-wall bounds. Does not prove angular ownership, endpoint/corner continuity, all player floors, or opacity outside the frozen source model.',
            selection=dict(primaryInstance=r['primaryInstanceIndex'],maximumNormalDeviationMeters=.03,includeRelief=include_relief,maximumAbsNormalZ=None if include_relief else .025,minimumNormalAlignment=None if include_relief else .999))
        suffix='surface-slab-sections' if include_relief else 'continuous-sections'
        (folder/f'span-{sid}-{suffix}.json').write_text(json.dumps(result,indent=2)+'\n');print(name,sid,[(s['relativeEyeHeightMeters'],s['uncoveredLengthMeters']) for s in sections],flush=True)

if __name__=='__main__':
    parser=argparse.ArgumentParser();parser.add_argument('map',choices=CHOICES);parser.add_argument('--include-relief',action='store_true');args=parser.parse_args();main(args.map,args.include_relief)

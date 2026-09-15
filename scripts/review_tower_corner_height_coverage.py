"""Find definite missing corner height intervals after source-depth collapse.

A tiny along-coordinate band conservatively overestimates surviving coverage.
Missing height intervals therefore flag review; a covered result does not prove
literal endpoint contact or preservation of the original depth silhouette.
"""
import gzip,json
from pathlib import Path
import numpy as np
import shapely
from tactical_alignment_audit import pack
from tactical_alignment_composite import explicit_warp
from verify_normalized_wall_profiles import profile_frame
from native_compact_wall_profiles import sha
REV=Path('E:/IcarusWorldAudit/2026-09-06/tactical-visibility-revision');folder=REV/'split-wall-family-normalized-candidate-v14';output=REV/'split-tower-independent-review-v14/corner-height-coverage.json';assert not output.exists();bindings=json.loads((folder/'bindings.json').read_text());families={f['edge']:f for f in bindings['families']};inventory=json.loads((output.parent/'clamp-discard-review.json').read_text());_,a=pack(folder/'split.height.bin.gz');p=np.load(folder/'normalized-face-provenance.npz');w=json.loads(gzip.decompress((REV/'display-warps-v1/split.display-warp.json.gz').read_bytes()));matrix=np.column_stack((w['projection']['axisU'],w['projection']['axisV']));origin=np.array(w['projection']['origin']);src=np.array(w['sourceNativeMeters']).reshape(-1,2)@matrix.T+origin;dst=np.array(w['targetAttackSvg']).reshape(-1,2);forward=explicit_warp(src,dst-src,np.array(w['triangles']).reshape(-1,3));regions={}
for edge,f in families.items():
    ids=p['generatedFaceIds'][p['generatedEdges']==edge];xyz=a['vertices'][a['faces'][ids]];svg=forward.apply((xyz[:,:,:2]@matrix.T+origin).reshape(-1,2)).reshape(-1,3,2);o,t,_=profile_frame(f,'target');profile=np.stack(((svg-o)@t,xyz[:,:,2]),axis=2);polygons=shapely.polygons(profile);valid=shapely.is_valid(polygons)&(shapely.area(polygons)>0);regions[edge]=shapely.union_all(polygons[valid])
rows=[]
for row in inventory['groups']:
    edge=row['edge'];f=families[edge];fragment=np.array(row['fragments'][0]['sourceSvgRelativeZ']);so,st,_=profile_frame(f,'source');salong=(fragment[:,:2]-so)@st;end=0 if salong.max()<f['sourceAlong'][0] else 1;to,tt,_=profile_frame(f,'target');corner=to+tt*f['targetAlong'][end];neighbors=[];covered=[]
    for other,g in families.items():
        go,gt,gn=profile_frame(g,'target');along=float((corner-go)@gt)
        if abs(float((corner-go)@gn))>1e-7 or along<g['targetAlong'][0]-1e-7 or along>g['targetAlong'][1]+1e-7:continue
        neighbors.append(other);band=regions[other].intersection(shapely.box(along-1e-7,-100,along+1e-7,100))
        for part in shapely.get_parts(band):
            if part.is_empty:continue
            zlo,zhi=part.bounds[1],part.bounds[3]
            if zhi>zlo:covered.append(shapely.LineString([[0,zlo],[0,zhi]]))
    source_z=np.concatenate([np.array(frag['sourceSvgRelativeZ'])[:,2] for frag in row['fragments']]);zlo,zhi=float(source_z.min()),float(source_z.max());required=shapely.LineString([[0,zlo],[0,zhi]]);missing=required.difference(shapely.union_all(covered));gaps=[shapely.get_coordinates(part)[:,1].tolist() for part in shapely.get_parts(missing) if part.length>1e-7]
    rows.append(dict(edge=edge,originalSourceFace=row['originalSourceFace'],cornerSvg=corner.tolist(),neighbors=neighbors,requiredControlHeight=[zlo,zhi],uncoveredHeightIntervals=gaps))
report=dict(scope=__doc__,candidateSha256=sha(folder/'split.height.bin.gz'),inventorySha256=sha(output.parent/'clamp-discard-review.json'),scriptSha256=sha(Path(__file__)),conservativeAlongBandSvg=1e-7,groups=rows,uncoveredGroups=sum(bool(r['uncoveredHeightIntervals']) for r in rows),productionMutation=False);output.write_text(json.dumps(report,indent=2)+'\n');print(json.dumps([r for r in rows if r['uncoveredHeightIntervals']],indent=2))

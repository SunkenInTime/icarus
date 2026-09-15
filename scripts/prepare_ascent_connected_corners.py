"""Source-backed Ascent corner proposals; no normalized candidate is baked."""
import gzip,json
from pathlib import Path
from collections import Counter
import numpy as np
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
from matplotlib.collections import PolyCollection
from mpl_toolkits.mplot3d.art3d import Poly3DCollection
from native_compact_wall_profiles import sha
ROOT=Path('E:/IcarusWorldAudit/2026-09-06');REV=ROOT/'tactical-visibility-revision';OUT=REV/'ascent-connected-corner-review-v1';OUT.mkdir(exist_ok=True)

def frame(a,b):
    a,b=np.array(a),np.array(b);t=b-a;length=np.linalg.norm(t);t/=length
    return dict(origin=a.tolist(),tangent=t.tolist(),normal=[-float(t[1]),float(t[0])]),float(length)

def prepare():
    coverage_path=REV/'all-map-wall-span-coverage-v1/ascent/attack.coverage.json.gz';c=json.loads(gzip.decompress(coverage_path.read_bytes()));spans={s['span']:s for s in c['spans']};path=ROOT/'supplemented-v2/world/ascent/geometry.npz';a=np.load(path);points,faces=a['points'],a['faces'];meta=json.loads(path.with_suffix('.json').read_text());warp_path=REV/'display-warps-v1/ascent.display-warp.json.gz';w=json.loads(gzip.decompress(warp_path.read_bytes()));matrix=np.column_stack((w['projection']['axisU'],w['projection']['axisV']));origin=np.array(w['projection']['origin']);primaries={141:6499,142:6499,143:6499,144:6506,145:6506,211:6879,212:6877,213:6877,214:6877,215:6877};rows=[]
    for span_id,obj in primaries.items():
        span=spans[span_id];tf,length=frame(span['startSvg'],span['endSvg']);tangent=np.array(tf['tangent']);normal=np.array(tf['normal']);samples=[r for r in c['samples'] if r['span']==span_id and r.get('sourceObjectIndex')==obj and r['relativeEyeHeightMeters']==1.75 and r.get('probeStartInsideReceiver')];seed_ids=sorted({r['originalSourceFace'] for r in samples});seed_tri=points[faces[seed_ids]].copy();seed_tri[:,:,:2]=seed_tri[:,:,:2]@matrix.T+origin
        seed_planes=[]
        for fid,triangle in zip(seed_ids,seed_tri):
            n=np.cross(triangle[1]-triangle[0],triangle[2]-triangle[0]);norm=np.linalg.norm(n[:2]);n=n/norm if norm else n
            if abs(n[2])>.005 or abs(n[:2]@normal)<.9999:continue
            if n[:2]@normal<0:n=-n
            offset=float((triangle[:,:2]@n[:2]).mean());existing=next((r for r in seed_planes if abs(r['offset']-offset)<.001 and np.dot(r['normal'],n[:2])>.999999),None)
            if existing is None:existing=dict(normal=n[:2].tolist(),offset=offset,seeds=[]);seed_planes.append(existing)
            existing['seeds'].append(int(fid))
        seed_planes.sort(key=lambda r:-sum(s['originalSourceFace'] in r['seeds'] for s in samples))
        item=meta['objects'][obj];ids=np.arange(item['firstFace'],item['firstFace']+item['faceCount']);triangles=points[faces[ids]].copy();triangles[:,:,:2]=triangles[:,:,:2]@matrix.T+origin;cross=np.cross(triangles[:,1]-triangles[:,0],triangles[:,2]-triangles[:,0]);norm=np.linalg.norm(cross,axis=1);unit=cross/np.maximum(norm[:,None],1e-30)
        for group in seed_planes:
            n=np.array(group['normal']);distance=np.max(abs(triangles[:,:,:2]@n-group['offset']),axis=1);aligned=(abs(unit[:,:2]@n)>.99999)&(abs(unit[:,2])<.005);candidate=ids[aligned&(distance<.001)];selected=triangles[aligned&(distance<.001)];group['sourceFaces']=candidate.tolist();group['originalSourceTrianglesSvgZ']=selected.tolist();group['normalInventoryToleranceSvg']=.001;group['standingContacts']=sum(s['originalSourceFace'] in group['seeds'] for s in samples);group['alongBoundsSvg']=[float((selected[:,:,:2]@tangent).min()),float((selected[:,:,:2]@tangent).max())] if len(selected) else None
        rows.append(dict(span=span_id,targetFrame=tf,targetAlong=[0,length],targetEndpoints=[span['startSvg'],span['endSvg']],legacyStraightEdgeIndex=span['legacyStraightEdgeIndex'],sourceObjectIndex=obj,sourceObjectPath=item['path'],sourcePlanes=seed_planes,standingContacts=len(samples),otherStandingObjects=dict(Counter(str(r.get('sourceObjectIndex')) for r in c['samples'] if r['span']==span_id and r['relativeEyeHeightMeters']==1.75 and r.get('sourceObjectIndex')!=obj)),status='Source-plane inventory, not complete ownership certification'))
    report=dict(scope=__doc__,sourceGeometrySha256=meta['geometrySha256'],sourceFileSha256=sha(path),coverageSha256=sha(coverage_path),warpSha256=sha(warp_path),scriptSha256=sha(Path(__file__)),families=rows,productionMutation=False)
    (OUT/'source-planes.json').write_text(json.dumps(report,indent=2)+'\n');print(json.dumps([{k:r[k] for k in ['span','sourceObjectIndex','standingContacts']}|dict(planes=[dict(offset=p['offset'],normal=p['normal'],along=p['alongBoundsSvg'],seeds=len(p['seeds']),faces=len(p['sourceFaces']),contacts=p['standingContacts']) for p in r['sourcePlanes']]) for r in rows],indent=2))
if __name__=='__main__':prepare()

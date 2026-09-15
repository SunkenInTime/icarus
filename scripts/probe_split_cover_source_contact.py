"""Raw-height section evidence for the two cover-to-body attachment corners."""
import gzip,json
import numpy as np
from declare_split_component2_cover_region import declarations,REV
from authored_region_cells import region_fragments
from tactical_alignment_composite import explicit_warp
from render_split_remaining_corner_families import sections

def distance(point,lines):
    if not len(lines):return None
    a=lines[:,0];d=lines[:,1]-a;n=(d*d).sum(1);u=np.divide(((point-a)*d).sum(1),n,out=np.zeros(len(n)),where=n>0);hit=a+np.clip(u,0,1)[:,None]*d
    return float(np.linalg.norm(hit-point,axis=1).min())

def main():
    body,cover=declarations();w=json.loads(gzip.decompress((REV/'display-warps-v1/split.display-warp.json.gz').read_bytes()));m=np.column_stack((w['projection']['axisU'],w['projection']['axisV']));o=np.array(w['projection']['origin']);s=np.array(w['sourceNativeMeters']).reshape(-1,2)@m.T+o;t=np.array(w['targetAttackSvg']).reshape(-1,2);unwarp=explicit_warp(t,s-t,np.array(w['triangles']).reshape(-1,3));original_body=np.load(REV/'split-component2-source-review-v1/full-objects-source-packet.npz')['sourceSvgTriangles'];original_cover=np.load(REV/'split-component2-cover-review-v1/cover-source.npz')['sourceTrianglesSvgZ'];meshes=[]
    for family,triangles in [(body,original_body),(cover,original_cover)]:
        mapped=[]
        for tri in triangles:
            for part,_,_ in region_fragments(np.column_stack((tri,np.eye(3))),family,unwarp):
                for i in range(1,len(part)-1):mapped.append(part[[0,i,i+1],:3])
        meshes.append(np.array(mapped))
    events=np.unique(original_cover[:,:,2]);events=events[(events>=0)&(events<=original_cover[:,:,2].max())];heights=sorted(set(((events[:-1]+events[1:])/2).tolist()+[.75,1.75,3.5]));rows=[]
    for z in heights:
        body_lines,_=sections(meshes[0],z);cover_lines,_=sections(meshes[1],z)
        for name,point in [('left',[417.298,134.959]),('right',[424.741,134.959])]:rows.append(dict(sourceZ=z,corner=name,bodyDistanceSvg=distance(np.array(point),body_lines),coverDistanceSvg=distance(np.array(point),cover_lines)))
    report=dict(scope='Absolute raw-source height sections of declared mapping. No tactical ground-field assumption. Midpoints of all source cover Z events plus three named heights; exact event endpoints are not an all-height certificate.',rows=rows,maximumBodyContactDistanceSvg=max(r['bodyDistanceSvg'] for r in rows if r['bodyDistanceSvg'] is not None),maximumCoverContactDistanceSvg=max(r['coverDistanceSvg'] for r in rows if r['coverDistanceSvg'] is not None));out=REV/'split-component2-cover-region-proposal-v1';(out/'source-height-contact-sections.json').write_text(json.dumps(report,indent=2));print({k:v for k,v in report.items() if k not in ['scope','rows']})

if __name__=='__main__':main()

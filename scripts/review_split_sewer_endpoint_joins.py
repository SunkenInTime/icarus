"""Inspect only the two held sewer joints and the existing barrier contact."""
import gzip
import io
import json
from pathlib import Path
import numpy as np
import shapely
from PIL import Image,ImageDraw,ImageFont
import resvg_py
from authored_region_cells import barycentric
from declare_split_legacy105_connected_region import ROOT,REV,sha
from render_split_remaining_corner_families import sections
from tactical_alignment_composite import explicit_warp


def main():
    out=REV/'split-sewer-endpoint-join-review-v2';out.mkdir(exist_ok=False)
    paths=[REV/'split-sewer108-connected-proposal-v7/region-declaration.json',
           REV/'split-sewer117-simple-proposal-v1/region-declaration.json',
           REV/'split-sewer147-return-proposal-v1/region-declaration.json']
    families=[json.loads(p.read_text()) for p in paths]
    before_path=REV/'split-sewer108-connected-proposal-v5/region-declaration.json';before108=json.loads(before_path.read_text())
    old_path=REV/'split-wall-family-normalized-candidate-v31-precise-v1/bindings.json'
    old=next(f for f in json.loads(old_path.read_text())['families'] if f['edge']==200123)
    gp=ROOT/'supplemented-v2/world/split/geometry.npz';raw=np.load(gp);meta=json.loads(gp.with_suffix('.json').read_text())
    wp=REV/'display-warps-v1/split.display-warp.json.gz';w=json.loads(gzip.decompress(wp.read_bytes()))
    mat=np.column_stack((w['projection']['axisU'],w['projection']['axisV']));offset=np.array(w['projection']['origin'])
    ws=np.array(w['sourceNativeMeters']).reshape(-1,2)@mat.T+offset;wt=np.array(w['targetAttackSvg']).reshape(-1,2)
    forward=explicit_warp(ws,wt-ws,np.array(w['triangles']).reshape(-1,3))
    cache={}
    def prepare(f):
        key=id(f)
        if key not in cache:
            s=np.array(f['sourceVerticesSvg']);t=np.array(f['targetVerticesSvg']);c=np.array(f['triangles'])
            polys=shapely.polygons(s[c]);rank={r['cell']:(np.array(d['targetEndpointsSvg']),np.array(r['vertexParameters'])) for d in f.get('declaredRankOneMappings',[]) for r in d['cells']}
            cache[key]=(s,t,c,polys,shapely.STRtree(polys),shapely.union_all(polys),rank)
        return cache[key]
    def mapped(line,f):
        if f is None:return [forward.apply(line)]
        s,t,c,polys,tree,domain,rank=prepare(f);geom=shapely.LineString(line);result=[]
        for ci in tree.query(geom,predicate='intersects'):
            for part in shapely.get_parts(shapely.intersection(geom,polys[ci])):
                if not isinstance(part,shapely.LineString) or part.length==0:continue
                p=np.array(part.coords);weights=barycentric(p,s[c[ci]]);q=weights@t[c[ci]]
                if int(ci) in rank:
                    endpoints,param=rank[int(ci)];q=endpoints[0]+(weights@param)[:,None]*(endpoints[1]-endpoints[0])
                result.append(q)
        for part in shapely.get_parts(shapely.difference(geom,domain)):
            if isinstance(part,shapely.LineString) and part.length:result.append(forward.apply(np.array(part.coords)))
        return result
    joint_rows=[]
    for name,a,b,box,point in [
        ('north',families[0],families[1],[356.81880941995377,families[1]['sourceBands']['bottom'][0],families[1]['sourceBands']['right'][1],families[1]['sourceBands']['bottom'][1]],[357.755,273.182]),
        ('south',families[0],families[2],[families[2]['sourceBands']['right'][0],families[2]['sourceBands']['top'][0],families[2]['sourceBands']['right'][1],families[2]['sourceBands']['top'][1]],[389.122,311.46])]:
        region=shapely.box(*box);errors=[];piece_count=0
        for f in [a,b]:
            s,t,c,polys,tree,domain,rank=prepare(f)
            assert shapely.difference(region,domain).area==0
            for ci in tree.query(region,predicate='intersects'):
                part=shapely.intersection(region,polys[ci]);p=shapely.get_coordinates(part)
                if not len(p):continue
                q=barycentric(p,s[c[ci]])@t[c[ci]]
                errors.extend(np.linalg.norm(q-np.array(point),axis=1).tolist());piece_count+=1
        maximum=max(errors);assert maximum<1e-10
        joint_rows.append(dict(name=name,sourceContactRectangle=box,authoredJoint=point,
            intersectedFieldCells=piece_count,maximumCommonContactErrorSvg=maximum))
    owners=sorted(set(old['objects'])|set(sum([f['objects'] for f in families],[])))
    meshes={}
    for oid in owners:
        o=meta['objects'][oid];tri=raw['points'][raw['faces'][o['firstFace']:o['firstFace']+o['faceCount']]].astype(float)
        tri[:,:,:2]=tri[:,:,:2]@mat.T+offset;meshes[oid]=tri
    heights=[3.25,4.85,6.75];profiles={}
    for z in heights:
        profiles[z]={'before':[],'after':[]}
        for oid,tri in meshes.items():
            seg,_=sections(tri,z)
            pre=before108 if oid in before108['objects'] else old if oid in old['objects'] else None
            post=next((f for f in families if oid in f['objects']),old if oid in old['objects'] else None)
            for line in seg:
                if np.linalg.norm(line[1]-line[0])==0:continue
                profiles[z]['before'].extend(mapped(line,pre));profiles[z]['after'].extend(mapped(line,post))
    reflection=np.array(w['attackToDefenseSvg']['origin']);font=ImageFont.truetype('C:/Windows/Fonts/segoeui.ttf',18)
    images=[]
    for focus,box in [('north-return',[[334.,241.],[365.,279.]]),('south-joint',[[383.,307.],[395.,320.]])]:
        width=int((box[1][0]-box[0][0])*8);height=int((box[1][1]-box[0][1])*8)
        column_width=max(width,230)
        sheet=Image.new('RGB',(4*(column_width+12)+12,3*(height+35)+80),'#17191f');draw=ImageDraw.Draw(sheet)
        draw.text((12,10),f'Sewer {focus} · exact field sections over native8x artwork',font=font,fill='white')
        draw.text((12,34),'Source-height controls; openings retained. Actual cone render remains the next gate.',font=font,fill='#c9d0d9')
        for col,(side,kind) in enumerate([('attack','before'),('attack','after'),('defense','before'),('defense','after')]):
            svg=Path('assets/maps/split_map'+('_defense' if side=='defense' else '')+'.svg')
            base=Image.open(io.BytesIO(resvg_py.svg_to_bytes(svg_string=svg.read_text(),zoom=8,background='#101014'))).convert('RGB')
            convert=lambda p:reflection-np.array(p) if side=='defense' else np.array(p)
            bb=convert(box);low=np.floor(bb.min(0)*8).astype(int);high=np.ceil(bb.max(0)*8).astype(int)
            for row,z in enumerate(heights):
                im=base.crop(tuple(np.r_[low,high]));d=ImageDraw.Draw(im)
                for line in profiles[z][kind]:d.line([tuple(p) for p in convert(line)*8-low],fill='#70e6ff',width=1)
                file=out/f'{focus}-{side}-{kind}-z{z:g}-native8x.png';im.save(file);images.append(str(file))
                x=12+col*(column_width+12);y=70+row*(height+35)
                draw.text((x,y),f'{side} {kind} Z{z:g}',font=font,fill='#e8edf3');sheet.paste(im,(x+(column_width-width)//2,y+25))
        sheet.save(out/f'{focus}-paired-native8x.png')
    report=dict(declarations=[dict(path=str(p),sha256=sha(p)) for p in paths],sourceGeometrySha256=sha(gp),scriptSha256=sha(Path(__file__)),
        commonJointRegions=joint_rows,images=images,productionMutation=False,
        retainedOldFamilyObjects=[o for o in old['objects'] if o!=6166],
        scope='Only the two demonstrated endpoint gaps. The common corner rectangles map to the same exact authored points in both adjacent fields. Original finite source heights remain; the actual app cone renderer is not simulated by these line overlays.')
    (out/'report.json').write_text(json.dumps(report,indent=2)+'\n')
    print(json.dumps(dict(joints=joint_rows,images=len(images),output=str(out))))


if __name__=='__main__':main()

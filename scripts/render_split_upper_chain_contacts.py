"""Original SVG artwork at native8x with held source sections and composed hits."""
import gzip,json
from pathlib import Path
import xml.etree.ElementTree as ET
import numpy as np
import resvg_py
import shapely
from render_split_remaining_corner_families import sections
from tactical_alignment_composite import explicit_warp
from lift_reviewed_wall_source_heights import sha

ROOT=Path('E:/IcarusWorldAudit/2026-09-06');REV=ROOT/'tactical-visibility-revision'


def main():
    out=REV/'split-upper-vent-chain-contacts-native8x-v1';out.mkdir(exist_ok=False)
    rp=REV/'split-room-upper-chain-standing-rays-v2/composed-rays.json';report=json.loads(rp.read_text())
    fp=REV/'split-room-upper-chain-combined-raw-v2/raw-source-fragments.npz';fr=np.load(fp)
    wp=REV/'display-warps-v1/split.display-warp.json.gz';w=json.loads(gzip.decompress(wp.read_bytes()))
    matrix=np.column_stack((w['projection']['axisU'],w['projection']['axisV']));origin=np.array(w['projection']['origin'])
    ws=np.array(w['sourceNativeMeters']).reshape(-1,2)@matrix.T+origin;wt=np.array(w['targetAttackSvg']).reshape(-1,2);cells=np.array(w['triangles']).reshape(-1,3)
    forward=explicit_warp(ws,wt-ws,cells);flip=np.array(w['attackToDefenseSvg']['origin'])
    shapes=shapely.polygons(ws[cells]);tree=shapely.STRtree(shapes)
    original=fr['trianglesNativeSourceZ'].copy();original[:,:,:2]=original[:,:,:2]@matrix.T+origin
    ns='http://www.w3.org/2000/svg';outputs=[]
    cases=[('172-middle',403,[286,165,296,175]),
        ('172-right-return',415,[294,165,302,174]),
        ('169-top',416,[278,99,287,106]),
        ('169-frame',426,[278,106,287,113]),
        ('169-170-corner',486,[278,136,289,145]),
        ('170-middle',500,[286,135,295,145]),
        ('170-171-corner',511,[294,135,303,145]),
        ('171-elevator-panel',516,[295,143,306,151]),
        ('171-wall-poster',520,[295,154,306,162]),
        ('171-172-corner',533,[295,164,306,173])]
    for name,index,box in cases:
        row=report['records'][index]
        source_lines,_=sections(original,row['originalEye'][2])
        mapped_lines=[forward.apply(line) for line in source_lines]
        physical=np.array([row['originalEye'],row['originalTarget']])[:,:2]@matrix.T+origin
        ray=shapely.LineString(physical);path=[]
        for cell in tree.query(ray,predicate='intersects'):
            for part in shapely.get_parts(shapely.intersection(ray,shapes[cell])):
                if part.geom_type=='LineString' and part.length>0:path.append(forward.apply(np.array(part.coords)))
        for side,name_svg in [('attack','split_map.svg'),('defense','split_map_defense.svg')]:
            transform=lambda p:np.asarray(p) if side=='attack' else flip-np.asarray(p)
            art=Path('assets/maps')/name_svg;root=ET.fromstring(art.read_text())
            bb=transform(np.array([box[:2],box[2:]]));lo,hi=bb.min(0),bb.max(0);size=np.rint((hi-lo)*8).astype(int)
            root.set('viewBox',f'{lo[0]} {lo[1]} {hi[0]-lo[0]} {hi[1]-lo[1]}');root.set('width',str(size[0]));root.set('height',str(size[1]))
            group=ET.SubElement(root,f'{{{ns}}}g',{'fill':'none','stroke':'#60ed91','stroke-width':'0.085'})
            for line in mapped_lines:
                if not ((line.max(0)>=box[:2]).all() and (line.min(0)<=box[2:]).all()):continue
                p=transform(line);ET.SubElement(group,f'{{{ns}}}polyline',{'points':' '.join(f'{x},{y}' for x,y in p)})
            for line in path:
                p=transform(line);ET.SubElement(root,f'{{{ns}}}polyline',{'points':' '.join(f'{x},{y}' for x,y in p),'fill':'none','stroke':'#bd86ff','stroke-width':'.07'})
            for key,color,radius in [('before','#ffb34d',.10),('after','#ff4f58',.08)]:
                if row[key]:
                    p=transform(row[key]['displaySvg']);ET.SubElement(root,f'{{{ns}}}circle',{'cx':str(p[0]),'cy':str(p[1]),'r':str(radius),'fill':color})
            raw=ET.tostring(root,encoding='unicode');stem=f'{side}-{name}-native8x'
            (out/f'{stem}.svg').write_text(raw)
            (out/f'{stem}.png').write_bytes(resvg_py.svg_to_bytes(svg_string=raw,background='#181a1f'))
            outputs.append(dict(case=name,side=side,png=f'{stem}.png',svg=f'{stem}.svg',artSha256=sha(art),pixelsPerSvgUnit=8,query=row))
    (out/'manifest.json').write_text(json.dumps(dict(sourceReportSha256=sha(rp),sourceFragmentSha256=sha(fp),scriptSha256=sha(Path(__file__)),outputs=outputs,
        legend='Unchanged actual SVG artwork. Green is original-height section geometry, including alpha-face bounds. Purple is the physical ray projected through W. Orange is old first hit; red is composed held-field first hit with the original alpha policy. Source diagnostic only; not an app cone render.'),indent=2)+'\n')
    print(json.dumps(dict(output=str(out),images=len(outputs))))


if __name__=='__main__':main()

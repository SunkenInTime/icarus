"""Actual attack/defense artwork with source-section contacts at8px per SVG unit."""
import gzip
import json
import xml.etree.ElementTree as ET

import resvg_py
import numpy as np
import shapely

from authored_region_cells import barycentric
from declare_split_legacy105_connected_region import ROOT, REV, sha
from render_split_remaining_corner_families import sections
from tactical_alignment_composite import explicit_warp


def main():
    out=REV/'split-legacy105-lower-receiver-review-v2'
    report_path=out/'first-hit-controls.json';report=json.loads(report_path.read_text())
    family_path=REV/'split-legacy105-connected-region-proposal-v2/region-declaration.json';family=json.loads(family_path.read_text())
    s=np.array(family['sourceVerticesSvg']);t=np.array(family['targetVerticesSvg']);c=np.array(family['triangles'])
    polygons=shapely.polygons(s[c]);tree=shapely.STRtree(polygons);domain=shapely.box(*family['box'])
    w=json.loads(gzip.decompress((REV/'display-warps-v1/split.display-warp.json.gz').read_bytes()))
    matrix=np.column_stack((w['projection']['axisU'],w['projection']['axisV']));origin=np.array(w['projection']['origin']);inverse=np.linalg.inv(matrix)
    ws=np.array(w['sourceNativeMeters']).reshape(-1,2)@matrix.T+origin;wt=np.array(w['targetAttackSvg']).reshape(-1,2);wc=np.array(w['triangles']).reshape(-1,3)
    forward=explicit_warp(ws,wt-ws,wc)
    sides=json.loads((ROOT/'tactical-alignment-sides-v1/split.json').read_text());dm=np.array(sides['nativeToDefenseSvg'])
    raw=np.load(ROOT/'supplemented-v2/world/split/geometry.npz');points=raw['points'];faces=raw['faces'];q=points[faces[np.array(family['reviewedSourceFaces'])]].copy();q[:,:,:2]=q[:,:,:2]@matrix.T+origin
    def transform(p,side):
        p=np.asarray(p,dtype=float)
        return p if side=='attack' else ((p-origin)@inverse.T)@dm[:,:2].T+dm[:,2]
    def lines(z):
        source,_=sections(q,z);result=[]
        for line in source:
            segment=shapely.LineString(line)
            for cell in tree.query(segment,predicate='intersects'):
                for part in shapely.get_parts(segment.intersection(polygons[cell])):
                    if part.geom_type=='LineString' and part.length>0:
                        result.append(barycentric(np.array(part.coords),s[c[cell]])@t[c[cell]])
            for part in shapely.get_parts(segment.difference(domain)):
                if part.geom_type=='LineString' and part.length>0:result.append(forward.apply(np.array(part.coords)))
        return result
    outputs=[];ns='http://www.w3.org/2000/svg'
    cases=[('bottom-wall',4,[310,327.90],[303,320,314,330]),
           ('corner-depth',1,[300,310.95],[287,303,319,318]),
           ('lower-reentry',5,[300,327.90],[291,324,317,342])]
    for name,oid,target,box in cases:
        record=next(r for r in report['records'] if r['originId']==oid and r['targetSvg']==target)
        eye=report['fixtures'][oid];geometry=lines(eye['originalEye'][2])
        for side,art in [('attack','split_map.svg'),('defense','split_map_defense.svg')]:
            from pathlib import Path
            art_path=Path('assets/maps')/art;root=ET.fromstring(art_path.read_text())
            corners=transform([[box[0],box[1]],[box[2],box[3]]],side);lo=corners.min(0);hi=corners.max(0);size=np.rint((hi-lo)*8).astype(int)
            root.set('viewBox',f'{lo[0]} {lo[1]} {hi[0]-lo[0]} {hi[1]-lo[1]}');root.set('width',str(size[0]));root.set('height',str(size[1]))
            group=ET.SubElement(root,f'{{{ns}}}g',{'fill':'none','stroke':'#63e89b','stroke-width':'0.065'})
            for line in geometry:
                p=transform(line,side);ET.SubElement(group,f'{{{ns}}}polyline',{'points':' '.join(f'{x},{y}' for x,y in p)})
            for line in record['displayPath']:
                p=transform(line,side);ET.SubElement(root,f'{{{ns}}}polyline',{'points':' '.join(f'{x},{y}' for x,y in p),'fill':'none','stroke':'#de8dff','stroke-width':'0.07'})
            for label,point,color,radius in [('eye',eye['displayedOriginSvg'],'#ffffff',.22),('target',target,'#d783ff',.12)]:
                p=transform(point,side);ET.SubElement(root,f'{{{ns}}}circle',{'cx':str(p[0]),'cy':str(p[1]),'r':str(radius),'fill':color})
            if record['proposedHybridHit']:
                p=transform(record['proposedHybridHit']['displayedHitSvg'],side);ET.SubElement(root,f'{{{ns}}}circle',{'cx':str(p[0]),'cy':str(p[1]),'r':'.12','fill':'#ff5050'})
            stem=f'{side}-{name}-native8x';svg_path=out/f'{stem}.svg';svg_path.write_bytes(ET.tostring(root));png_path=out/f'{stem}.png'
            png_path.write_bytes(resvg_py.svg_to_bytes(svg_string=ET.tostring(root,encoding='unicode'),background='#181a1f'))
            outputs.append(dict(side=side,case=name,png=png_path.name,svg=svg_path.name,artSha256=sha(art_path),pixelsPerSvgUnit=8,absoluteStandingEye=eye['originalEye'],queryRecord=record))
    (out/'native8x-context-manifest.json').write_text(json.dumps(dict(sourceReportSha256=sha(report_path),declarationSha256=sha(family_path),outputs=outputs,
        legend='Original artwork; thin green=proposed original-height source sections, violet=physical ray projected throughW, white=nav standing origin, red=first hit. These are source-diagnostic overlays, not an app renderer capture.'),indent=2)+'\n')


if __name__=='__main__':main()

"""Native-8x artwork overlays from verified finite original-height source fragments."""
import argparse
import gzip
import io
import json
from pathlib import Path
import numpy as np
from PIL import Image,ImageDraw,ImageFont
import resvg_py

from declare_split_legacy105_connected_region import ROOT,REV,sha
from render_split_remaining_corner_families import sections
from tactical_alignment_composite import explicit_warp


def main(proposal, finite, output):
    output.mkdir(exist_ok=False)
    family=json.loads((proposal/'region-declaration.json').read_text())
    gate=json.loads((finite/'report.json').read_text())
    assert gate['declarationSha256']==sha(proposal/'region-declaration.json')
    packet=np.load(finite/'source-and-mapped-fragments.npz')
    assert gate['fragmentPacketSha256']==sha(finite/'source-and-mapped-fragments.npz')
    p=ROOT/'supplemented-v2/world/split/geometry.npz'
    raw=np.load(p)
    wp=REV/'display-warps-v1/split.display-warp.json.gz'
    w=json.loads(gzip.decompress(wp.read_bytes()))
    matrix=np.column_stack((w['projection']['axisU'],w['projection']['axisV']))
    origin=np.array(w['projection']['origin'])
    ws=np.array(w['sourceNativeMeters']).reshape(-1,2)@matrix.T+origin
    wt=np.array(w['targetAttackSvg']).reshape(-1,2)
    forward=explicit_warp(ws,wt-ws,np.array(w['triangles']).reshape(-1,3))
    original=raw['points'][raw['faces'][family['reviewedSourceFaces']]].astype(float)
    original[:,:,:2]=original[:,:,:2]@matrix.T+origin
    proposed=np.concatenate((packet['mappedSvg'],packet['originalSourceXyz'][:,:,2:]),axis=2)
    nearby=np.load(REV/'split-sewer108-connected-source-review-v4/nearby-original-source.npz')
    retained=np.load(REV/'full-height-input-v1/split/source-correspondence.npz')['sourceFaces']
    other=~np.isin(nearby['rawSourceFaces'],family['reviewedSourceFaces']) & np.isin(nearby['rawSourceFaces'],retained)
    neighbors=nearby['originalTriangles'][other].copy()
    neighbors[:,:,:2]=neighbors[:,:,:2]@matrix.T+origin
    heights=[2.75,3.25,4.85,5.75,6.75,8.25]
    boxes={'assembly':[[350.,250.],[411.,318.]],'north-join':[[354.,269.],[361.,277.]],
           'south-join':[[385.,308.],[394.,318.]],'rear-grate':[[364.,286.],[372.,307.]]}
    reflection=np.array(w['attackToDefenseSvg']['origin'])
    records=[]
    for side in ['attack','defense']:
        svg=Path('assets/maps/split_map'+('_defense' if side=='defense' else '')+'.svg')
        base=Image.open(io.BytesIO(resvg_py.svg_to_bytes(svg_string=svg.read_text(),zoom=8,background='#101014'))).convert('RGB')
        convert=lambda p:reflection-np.array(p) if side=='defense' else np.array(p)
        for z in heights:
            originals,_=sections(original,z)
            originals=[forward.apply(line) for line in originals]
            proposals,_=sections(proposed,z)
            other_lines,_=sections(neighbors,z)
            other_lines=[forward.apply(line) for line in other_lines]
            for name,box in boxes.items():
                bb=convert(box)
                lower=np.floor(bb.min(0)*8).astype(int)
                upper=np.ceil(bb.max(0)*8).astype(int)
                for kind,lines in [('original',originals),('proposal',proposals)]:
                    im=base.crop(tuple(np.r_[lower,upper]))
                    draw=ImageDraw.Draw(im)
                    for line in other_lines:
                        draw.line([tuple(p) for p in convert(line)*8-lower],fill='#d59447',width=1)
                    for line in lines:
                        draw.line([tuple(p) for p in convert(line)*8-lower],fill='#6be5ff',width=1)
                    file=output/f'{side}-{name}-z{z:g}-{kind}-native8x.png'
                    im.save(file)
                    records.append(dict(side=side,focus=name,originalZ=z,kind=kind,path=str(file),
                        width=im.width,height=im.height,sha256=sha(file),artworkSha256=sha(svg)))
    font=ImageFont.truetype('C:/Windows/Fonts/segoeui.ttf',18)
    for page,zs in enumerate([heights[:3],heights[3:]],1):
        sheet=Image.new('RGB',(2010,1820),'#17191f')
        draw=ImageDraw.Draw(sheet)
        draw.text((15,10),'Split source profiles over unchanged artwork — native 8x, no cone renderer',font=font,fill='#f5f5f5')
        draw.text((15,36),'Cyan: reviewed source. Orange: separate original source. Masked sheets shown without alpha sampling.',font=font,fill='#d5d9e0')
        draw.text((15,62),'Both terminal seams remain held: 6166/6170 at wall117; 6168 at wall147. Not accepted for staging.',font=font,fill='#ffca75')
        for row,z in enumerate(zs):
            for col,(side,kind) in enumerate([('attack','original'),('attack','proposal'),('defense','original'),('defense','proposal')]):
                record=next(r for r in records if r['focus']=='assembly' and r['side']==side and r['kind']==kind and r['originalZ']==z)
                x=15+col*495;y=110+row*564
                draw.text((x,y),f'{side} {kind} · Z {z:g} m',font=font,fill='#e7ebf0')
                sheet.paste(Image.open(record['path']),(x,y+25))
        sheet.save(output/f'paired-source-art-page-{page:02}.png')
    report=dict(declarationSha256=sha(proposal/'region-declaration.json'),
        finiteSourceReportSha256=sha(finite/'report.json'),scriptSha256=sha(Path(__file__)),
        sourceWarpSha256=sha(wp),records=records,productionMutation=False,
        scope='Native8x rasterization of the actual attack/defense SVG assets with original-Z sections. Proposal sections come from the verified finite source fragments. No rescaling of crops, SVG edits, runtime cone rendering, mask-alpha claim or final standing-target visibility claim.',
        heldInterfaces=['116/117: unmatched source6166/6170 remains at X357.483, proposal endpoint X357.755.',
                        '146/147: unmatched source6168 remains at X388.770959, proposal endpoint X389.122.'])
    (output/'report.json').write_text(json.dumps(report,indent=2)+'\n')
    print(json.dumps(dict(images=len(records),pages=2,output=str(output))))


if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--proposal',type=Path,required=True)
    p.add_argument('--finite',type=Path,required=True)
    p.add_argument('--output',type=Path,required=True)
    a=p.parse_args();main(a.proposal,a.finite,a.output)

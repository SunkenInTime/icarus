"""Show all frozen105 baseline contact crops at their original2x/8x pixels."""
import json
from pathlib import Path
from PIL import Image,ImageDraw,ImageFont
from native_compact_wall_profiles import sha


def main():
    rev=Path('E:/IcarusWorldAudit/2026-09-06/tactical-visibility-revision');source=rev/'105-contact-v30-baseline-v1';out=rev/'105-v30-baseline-evidence-v1';out.mkdir(exist_ok=False)
    manifest=json.loads((source/'manifest.json').read_text());assert manifest['complete']
    validation=json.loads((source/'overlay-consistency.json').read_text());assert validation['passed']
    fixtures={r['id']:r for r in json.loads((rev/'split-105-v31-render-fixtures-v2/split-fixtures.json').read_text())['cases']}
    font=ImageFont.truetype('C:/Windows/Fonts/segoeui.ttf',13);small=ImageFont.truetype('C:/Windows/Fonts/segoeui.ttf',11);pages=[];records=[]
    for page,start in enumerate(range(0,len(manifest['cases']),16),1):
        canvas=Image.new('RGB',(1160,1160),'#18181b');labels=[]
        labels.extend([(12,8,f'Split105 V30 baseline. Page{page}. Original8x and2x pixels.',font,'white'),
            (12,31,'Source-directed standing poses; provisional floor field. Render range extends20cm beyond frozen receiver probe.',small,'#efc485')])
        for slot,row in enumerate(manifest['cases'][start:start+16]):
            x=12+(slot%4)*290;y=63+(slot//4)*272;fixture=fixtures[row['id']]
            labels.extend([(x,y,f'{row["side"]} / {row["id"]}',small,'white'),(x,y+17,f'Eye{fixture["relativeControlEyeMeters"]:.4f}m relative; {fixture["authoredSpan"]}',small,'#efc485')])
            sources=[]
            for scale in [8,2]:
                region=next(r for r in row['rasterRegions'] if r['name']=='focus' and r['kind']=='overlay' and r['scale']==scale)
                path=Path(region['path']);im=Image.open(path).convert('RGB');assert im.width<=162 and im.height<=162
                canvas.paste(im,(x,y+36 if scale==8 else y+208));labels.append((x+170,y+95 if scale==8 else y+219,f'{scale}x',small,'#dddddd'))
                sources.append(dict(path=str(path),sha256=sha(path),scale=scale,pixelRect=region['pixelRect']))
            records.append(dict(page=page,id=row['id'],side=row['side'],query=row['query'],sources=sources,
                contextFiles=[r for r in row['rasterRegions'] if r['name']=='context' and r['kind']=='overlay']))
        draw=ImageDraw.Draw(canvas)
        for x,y,text,font,color in labels:draw.text((x,y),text,font=font,fill=color)
        path=out/f'page-{page:02}.png';canvas.save(path);pages.append(dict(path=str(path),sha256=sha(path)))
    (out/'manifest.json').write_text(json.dumps(dict(pages=pages,records=records,sourceManifestSha256=sha(source/'manifest.json'),
        overlayChecks=validation['checkedViews'],scope=__doc__,noResampling=True),indent=2)+'\n')
    print(json.dumps(dict(folder=str(out),pages=len(pages),sideCases=len(records))))


if __name__=='__main__':main()

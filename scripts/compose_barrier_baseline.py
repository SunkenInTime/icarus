"""Native-pixel baseline sheets. No geometry or raster resampling."""
from pathlib import Path
import json,hashlib
from PIL import Image,ImageDraw,ImageFont
R=Path("E:/IcarusWorldAudit/2026-09-06/tactical-visibility-revision")
folder=R/"barrier-contact-v26";out=R/"barrier-baseline-v26-evidence";out.mkdir(exist_ok=True)
m=json.loads((folder/"manifest.json").read_text());assert m["complete"]
f={r["id"]:r for r in json.loads((R/"barrier-presentation-fixtures.json").read_text())["cases"]}
font=ImageFont.truetype("C:/Windows/Fonts/segoeui.ttf",10);title=ImageFont.truetype("C:/Windows/Fonts/segoeui.ttf",13)
records=[]
for side in ["attack","defense"]:
 rows=[r for r in m["cases"] if r["side"]==side];sheet=Image.new("RGB",(800,1080),"#18181b");draw=ImageDraw.Draw(sheet)
 draw.text((10,8),f"Split V26 untouched barrier baseline / {side} / native8x and2x",font=title,fill="white")
 draw.text((10,28),"Frozen physical source poses. Relative-height diagnostics; V28 is not rendered here.",font=font,fill="#efc485")
 for i,r in enumerate(rows):
  x=8+(i%4)*200;y=52+(i//4)*255
  label=r["id"].replace("barrier-","").replace("-interior-eye-"," / eye ").replace("-end-quadrant-"," / corner ")
  draw.text((x,y),label,font=font,fill="white")
  for scale,dy in [(8,20),(2,194)]:
   reg=next(a for a in r["rasterRegions"] if a["kind"]=="overlay" and a["scale"]==scale and a["name"]=="focus");im=Image.open(reg["path"]).convert("RGB");sheet.paste(im,(x,y+dy));draw.text((x+im.width+3,y+dy),f"{scale}x",font=font,fill="white")
  records.append(dict(id=r["id"],side=side,query=r["query"],meshSha256=r["meshSha256"]))
 path=out/f"{side}-baseline-native-pixels.png";sheet.save(path)
(out/"manifest.json").write_text(json.dumps(dict(scope=__doc__,sourceManifest=str(folder/"manifest.json"),cases=records,images=[dict(path=str(x),sha256=hashlib.sha256(x.read_bytes()).hexdigest()) for x in out.glob("*.png")]),indent=2))
print(out)

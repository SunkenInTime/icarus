"""Compare matching raw app crops with identical labels, preserving pixels."""
import json,hashlib,os
from pathlib import Path
import numpy as np
from PIL import Image,ImageDraw,ImageFont
R=Path("E:/IcarusWorldAudit/2026-09-06/tactical-visibility-revision")
before=R/os.environ.get("ICARUS_REGION_BEFORE","frozen-split-app-scene-v25-run1")
after=R/os.environ.get("ICARUS_REGION_AFTER","frozen-split-app-scene-v26-run1")
labels=(os.environ.get("ICARUS_REGION_BEFORE_LABEL","V25"),os.environ.get("ICARUS_REGION_AFTER_LABEL","V26"))
config=json.loads((R/"frozen-split-app-scene-v25-run1/aligned-comparisons/manifest.json").read_text())
out=after/"aligned-comparisons";out.mkdir(exist_ok=True)
font=ImageFont.truetype("C:/Windows/Fonts/segoeui.ttf",15)
images={};records=[]
for row in config["records"]:
 name=Path(row["image"]).name;side=name.split("-")[0]
 for p in (before,after):
  if (p,side) not in images:images[p,side]=Image.open(p/f"split-{side}-native8x.png").convert("RGB")
 a,b=[images[p,side].crop(row["pixelRect"]) for p in (before,after)]
 w,h=a.size;im=Image.new("RGB",(w*2+36,h+70),"#18181b");d=ImageDraw.Draw(im)
 for i,(img,label) in enumerate(zip((a,b),labels)):
  d.text((12+i*(w+12),10),f"{label} / {name[:-4]}",font=font,fill="white");im.paste(img,(12+i*(w+12),40))
 path=out/name;im.save(path)
 records.append({"image":str(path),"sha256":hashlib.sha256(path.read_bytes()).hexdigest(),"pixelRect":row["pixelRect"],"changedPixels":int(np.any(np.array(a)!=np.array(b),axis=2).sum()),"sourceRaw":[str(p/f"split-{side}-native8x.png") for p in (before,after)],"sameLabelOffset":[12,40]})
(out/"manifest.json").write_text(json.dumps({"scope":__doc__,"records":records},indent=2))
print("Wrote",len(records),"raw-aligned comparisons")

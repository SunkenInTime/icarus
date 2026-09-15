"""Prepare source-validated standing fixtures for the production cone painter."""
import json
import math
import numpy as np
import shapely
from shapely.affinity import affine_transform
from audit_all_map_gameplay_levels import MAPS,OUT,ROOT,read,planes
from compile_reviewed_svg_height_map import polygon
from build_all_map_gameplay_supports import support_elevation


def prepare(name):
 directory=OUT/name
 models={s:read(directory/f'candidate-{s}.json.gz') for s in ['attack','defense']}
 stage=OUT/'render-models';stage.mkdir(exist_ok=True)
 cases=[]
 for side,model in models.items():
  (stage/f'{name}-{side}.json').write_text(json.dumps(model,separators=(',',':')))
  vertices=np.array(model['ground']['vertices']).reshape(-1,3);tri=vertices[np.array(model['ground']['triangles']).reshape(-1,3)]
  tree=shapely.STRtree(shapely.polygons(tri[:,:,:2]));coeff=planes(tri)
  supports=[s for s in model['supports'] if s.get('automaticStandingAllowed')]
  stree=shapely.STRtree([polygon(s) for s in supports]);positions=[]
  for s in supports:
   for part in shapely.get_parts(polygon(s)):
    if part.geom_type!='Polygon' or part.area<.1:continue
    p=part.representative_point();positions.append((part.area,s,p))
  positions.sort(key=lambda r:-r[0]);rendered=[]
  for index,(area,s,p) in enumerate(positions):
   xy=np.array([p.x,p.y]);ids=tree.query(p,predicate='intersects');z=float(coeff[min(ids),:2]@xy+coeff[min(ids),2]) if len(ids) else 0.
   applicable=stree.query(p,predicate='intersects');expected=max([z]+[support_elevation(supports[i],xy) for i in applicable])+model['defaultCameraHeightMeters']
   render=side=='attack' and len(rendered)<12 and all(p.distance(q)>16 for q in rendered)
   if render:rendered.append(p)
   cases.append(dict(id=f'{side}-standing-{index}',side=side,originSvg=xy.tolist(),centerSvg=xy.tolist(),directionRadians=math.pi*.25*(index%8),rangeSvg=65.,apertureRadians=math.pi*.75,cropSizeSvg=130.,expectedEyeElevationMeters=expected,render=render,automatic=True,sourceSupport=s['id'],sourceSupportElevationMeters=support_elevation(s,xy)))
 (OUT/name/'production-cases.json').write_text(json.dumps(dict(cases=cases),indent=2))
 print(name,len(cases),'queries',sum(r['render'] for r in cases),'renders')

if __name__=='__main__':
 for name in MAPS:prepare(name)

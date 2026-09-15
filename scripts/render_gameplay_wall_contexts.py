"""Render named source structures against the unchanged SVG wall footprint."""
import argparse
import numpy as np
import shapely
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
from matplotlib.collections import PolyCollection
from mpl_toolkits.mplot3d.art3d import Poly3DCollection
from audit_all_map_gameplay_levels import OUT, ROOT, read
from compile_reviewed_svg_height_map import polygon

CASES={
 'ascent-boat':('ascent',['p2-stroke-6'],[7190,7265,7266,7267,7276]),
 'bind-crate':('bind',['p5-stroke-9'],[6603,6602]),
 'bind-pipes':('bind',['p6-stroke-0'],[6502,6537]),
 'fracture-boost':('fracture',['p13-stroke-7'],[4253,4254]),
 'fracture-floor-grating':('fracture',['p19-stroke-0'],[4236,4256]),
 'haven-shrine':('haven',['p3-stroke-6'],[7034,7033,7131]),
 'lotus-crates':('lotus',['p8-stroke-10'],[4552,4561]),
 'pearl-generator':('pearl',['p16-stroke-0'],[6960,6961,6962,6953]),
 'pearl-industrial':('pearl',['p23-stroke-9'],[6127,6128,6129]),
 'pearl-stack':('pearl',['p16-stroke-1'],[6929,6918,6919,6959,6925]),
 'abyss-tower':('abyss',['p8-stroke-0'],[5672,5633,5642,5663,5648,5644]),
 'fracture-tunnel':('fracture',['p18-stroke-1'],[4821,4813,4817,4725,4751,4753,4822]),
 'fracture-platform':('fracture',['p14-stroke-3'],[4235,4236,4237,4238,4214,4211]),
 'haven-a-box':('haven',['p3-stroke-19'],[229,230,6635,593]),
 'haven-mid-box':('haven',['p6-stroke-1'],[7191]),
 'icebox-ramp':('icebox',['p8-stroke-3'],[3717,3734,3715,3511,3512,3728,3740,3716]),
 'icebox-ledge':('icebox',['p4-stroke-2'],[3741,3590,3698]),
 'lotus-stepwell':('lotus',['p11-fill-0'],[4302,4301,4292,4289,4400]),
 'pearl-booth':('pearl',['p8-stroke-0','p29-stroke-0','p29-stroke-1'],[6964,6943,6944,6945,6950,6949]),
}

def render(key):
 name,wall_ids,ids=CASES[key]
 model=read(OUT/name/'candidate-attack.json.gz')
 objects=read(ROOT/f'supplemented-v2/world/{name}/geometry.json')['objects']
 mesh=np.load(ROOT/f'supplemented-v2/world/{name}/geometry.npz')
 matrix=np.array(read(ROOT/f'tactical-alignment-sides-v1/{name}.json')['nativeToAttackSvg'])
 fig=plt.figure(figsize=(15,7),layout='constrained');plan=fig.add_subplot(121);scene=fig.add_subplot(122,projection='3d')
 all_tri=[]
 for i,oid in enumerate(ids):
  o=objects[oid];tri=mesh['points'][mesh['faces'][o['firstFace']:o['firstFace']+o['faceCount']]].astype(float)
  tri[:,:,:2]=tri[:,:,:2]@matrix[:,:2].T+matrix[:,2];all_tri.append(tri)
  color=plt.get_cmap('tab10')(i%10)
  plan.add_collection(PolyCollection(tri[:,:,:2],facecolors=[color],edgecolors='none',alpha=.22))
  scene.add_collection3d(Poly3DCollection(tri,facecolors=[color],edgecolors='none',alpha=.35))
  scene.plot([],[],[],color=color,label=f'{oid} '+o['path'].split('/')[-2])
 for w in model['walls']:
  if not any(w['id'].startswith(wid) for wid in wall_ids):continue
  for ring in w['rings']:
   xy=np.array(ring).reshape(-1,2);plan.plot(xy[:,0],xy[:,1],color='black',lw=1)
  p=polygon(w).representative_point();plan.text(p.x,p.y,w['id'],fontsize=7)
 tri=np.concatenate(all_tri).reshape(-1,3);lo=tri.min(0);hi=tri.max(0)
 plan.set(xlim=(lo[0]-3,hi[0]+3),ylim=(hi[1]+3,lo[1]-3),aspect='equal',xlabel='SVG X',ylabel='SVG Y',title='Source shapes and painted wall edges')
 scene.set(xlim=(lo[0],hi[0]),ylim=(hi[1],lo[1]),zlim=(max(-2,lo[2]),min(22,hi[2])),title='Named source geometry',zlabel='Source elevation, m')
 scene.set_box_aspect([max(hi[0]-lo[0],10),max(hi[1]-lo[1],10),max((hi[2]-lo[2])*4,10)])
 scene.view_init(elev=28,azim=-65);scene.legend(loc='upper left',fontsize=6)
 fig.suptitle(key);directory=OUT/'wall-contexts';directory.mkdir(exist_ok=True)
 fig.savefig(directory/f'{key}.png',dpi=150);plt.close(fig)

if __name__=='__main__':
 p=argparse.ArgumentParser();p.add_argument('cases',nargs='*',default=list(CASES))
 for key in p.parse_args().cases:render(key)

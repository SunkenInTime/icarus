"""Declared near-jamb deformation with an unchanged far doorway."""
import json
import numpy as np
from build_split_connected_tower import REV

def declaration():
    rows=[147.,148.5,149.90749932307665,149.94472471144758,151.58434,153.,154.]
    source=[];target=[]
    for y in rows:
        right=344.075855+(y-149.934822)*(349.663794-344.075855)/(161.63639-149.934822)
        xs=[338.,341.6890156339508,341.8448820337362,right,right+.5,348.,350.]
        active=149.90<y<152.
        mapped_y=149.313 if y<=149.94472471144758 else 149.313+(y-149.90749932307665)/(157.72671004720826-149.90749932307665)*(157.819-149.313)
        mapped_right=344.465+(mapped_y-149.313)*(350.969-344.465)/(161.636-149.313)
        # Read the exact authored diagonal endpoint instead of relying on a
        # human-rounded coordinate in the presentation packet.
        declarations=json.loads((REV/'split-tower-connected-declarations-v15.json').read_text())
        wall=next(f for f in declarations['families'] if f['edge']==96)
        a,b=np.array(wall['sharedAuthoredJoins']);mapped_right=a[0]+(mapped_y-a[1])*(b[0]-a[0])/(b[1]-a[1])
        tx=[338.,343.401,343.401,mapped_right,mapped_right,348.,350.]
        for col,x in enumerate(xs):
            source.append([x,y]);target.append([tx[col],mapped_y] if active and 0<col<6 else [x,y])
    triangles=[]
    for row in range(len(rows)-1):
        for col in range(6):
            a=row*7+col;b=a+1;c=a+7;d=c+1
            triangles.extend([[a,b,d],[a,d,c]])
    source=np.array(source);target=np.array(target);triangles=np.array(triangles)
    def area(points):
        u=points[triangles[:,1]]-points[triangles[:,0]];v=points[triangles[:,2]]-points[triangles[:,0]]
        return u[:,0]*v[:,1]-u[:,1]*v[:,0]
    source_area=area(source);target_area=area(target)
    if source_area.min()<=0 or target_area.min() < -1e-10:raise ValueError('Region mesh folds')
    return dict(edge=20097,mappingType='piecewise-affine-region-v1',sourceVerticesSvg=source.tolist(),targetVerticesSvg=target.tolist(),triangles=triangles.tolist(),objects=[5896],reviewedSourceFaces=list(range(1880003,1880061)),box=[338.,147.,350.,154.],identityOuterBoundary=True,role='Connected near DoorFrameB jamb and local rail. Distant jamb and central doorway retain existing source geometry. No new height or visibility fill.',validation=dict(minSourceDoubleArea=float(source_area.min()),minTargetDoubleArea=float(target_area.min()),collapsedTargetCells=int((abs(target_area)<1e-10).sum())))

if __name__=='__main__':
    row=declaration();path=REV/'split-doorframe-attachment-review-v1/region-declaration.json';path.write_text(json.dumps(row,indent=2));print(path)

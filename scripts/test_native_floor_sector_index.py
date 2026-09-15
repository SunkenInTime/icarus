"""Same boundary controls applied to both native clipping paths."""
import math,unittest
import numpy as np
from test_floor_sector_index import FloorSectorIndexTest
from probe_native_floor_sector_index import NativeSector

class NativeFloorSectorTest(FloorSectorIndexTest):
    def compare(self,polygon,origin):
        model=NativeSector();angles=list(np.linspace(-math.pi,math.pi,361))
        for point in polygon:
            angle=math.atan2(point[1]-origin[1],point[0]-origin[0]);angles.extend(angle+d for d in [0.,-1e-13,1e-13,-1e-9,1e-9])
        rays=np.array([[math.cos(angle)*distance,math.sin(angle)*distance] for angle in angles for distance in [.01,1.,100.]])
        old=model.clips(polygon,origin,rays,False);new=model.clips(polygon,origin,rays,True);valid=old[:,1]>=old[:,0]
        np.testing.assert_array_equal(valid,new[:,1]>=new[:,0]);np.testing.assert_array_equal(old[valid,:2],new[valid,:2])
    def test_exact_vertex_uses_full_clip(self):
        angles=np.arange(35)*2*math.pi/35;polygon=np.column_stack([np.cos(angles),np.sin(angles)]);origin=np.array([2.,0.]);rows=NativeSector().clips(polygon,origin,polygon-origin,True)
        np.testing.assert_array_equal(rows[:,2],0)
if __name__=='__main__':unittest.main()

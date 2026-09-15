"""Regression for exact profile mapping across clamp and nonlinear W joins."""
import unittest
import numpy as np
from authored_wall_profile_cells import wall_breakpoints,frame_wall_breakpoints,normalized_fragments,inverse_in_cell,validated_frame
from tactical_alignment_composite import explicit_warp

class ProfileCellTest(unittest.TestCase):
    def test_rotated_source_and_target_frames_cross_clamps_and_w_cells(self):
        for angle in [27.,45.,-31.,137.]:
            with self.subTest(angle=angle):
                def frame(degrees,origin):
                    rad=np.deg2rad(degrees);u=np.array([np.cos(rad),np.sin(rad)])
                    return dict(origin=np.array(origin),tangent=u,normal=np.array([-u[1],u[0]]))
                source_frame=frame(angle+23,[-.3,.4]);target_frame=frame(angle,[1.,1.])
                target=np.array([[0,0],[2,0],[2,2],[0,2],[1,1]],float)
                source=target.copy();source[4]+=[.3,-.2]
                triangles=np.array([[0,1,4],[1,2,4],[2,3,4],[3,0,4]])
                inverse=explicit_warp(target,source-target,triangles);forward=explicit_warp(source,target-source,triangles)
                local=np.array([[-.3,.2,0],[2.3,.2,2],[.7,1.4,4]])
                xyz=local.copy();xyz[:,:2]=source_frame['origin']+local[:,0,None]*source_frame['tangent']+local[:,1,None]*source_frame['normal']
                family=dict(sourceFrame=source_frame,targetFrame=target_frame,sourceAlong=[0,2],targetAlong=[-.9,.9])
                family['displayWarpBreakpoints']=frame_wall_breakpoints(inverse,target_frame,-.9,.9)
                discarded=[];pieces=normalized_fragments(np.column_stack((xyz,np.eye(3))),family,inverse,discarded=discarded)
                self.assertGreater(len(set(cell for _,cell in pieces)),1)
                self.assertGreater(len(discarded),0)
                area=0.
                for part in [part for part,_ in pieces]+discarded:
                    for j in range(1,len(part)-1):area+=abs(float(np.linalg.det(part[[0,j,j+1],3:])))
                self.assertAlmostEqual(area,1.,places=12)
                for part,cell in pieces:
                    native=inverse_in_cell(part[:,:2],inverse,cell)
                    for j in range(1,len(part)-1):
                        for weights in [np.array([1,1,1])/3,np.array([.1,.2,.7]),np.array([.6,.35,.05])]:
                            ids=[0,j,j+1];original=(weights@part[ids,3:])@xyz
                            scalar=float((original[:2]-source_frame['origin'])@source_frame['tangent'])
                            expected=target_frame['origin']+(-.9+1.8*np.clip(scalar/2,0,1))*target_frame['tangent']
                            np.testing.assert_allclose(forward.apply(weights@native[ids]),expected,atol=2e-12,rtol=0)
                            self.assertAlmostEqual(float(weights@part[ids,2]),float(original[2]),places=12)

    def test_rejects_scaled_or_reflected_frames(self):
        for frame in [dict(origin=[0,0],tangent=[2,0],normal=[0,1]),dict(origin=[0,0],tangent=[1,0],normal=[0,-1]),dict(origin=[0,float('nan')],tangent=[1,0],normal=[0,1])]:
            with self.assertRaises(ValueError):validated_frame(frame)

    def test_clamp_and_cell_kinks_preserve_interior_correspondence(self):
        target=np.array([[0,0],[2,0],[2,2],[0,2],[1,1]],float)
        source=target.copy();source[4]+=[.3,-.2]
        triangles=np.array([[0,1,4],[1,2,4],[2,3,4],[3,0,4]])
        inverse=explicit_warp(target,source-target,triangles)
        forward=explicit_warp(source,target-source,triangles)
        xyz=np.array([[-.3,.2,0],[2.3,.2,2],[.7,1.4,4]])
        family=dict(axis=0,fixed=.6,sourceAlong=[0,2],targetAlong=[.1,1.9])
        family['displayWarpBreakpoints']=wall_breakpoints(inverse,0,.6,.1,1.9)
        discarded=[]
        pieces=normalized_fragments(np.column_stack((xyz,np.eye(3))),family,inverse,discarded=discarded)
        self.assertGreater(len(pieces),2)
        self.assertGreater(len(set(cell for _,cell in pieces)),1)
        checks=0
        for part,cell in pieces:
            native=inverse_in_cell(part[:,:2],inverse,cell)
            for j in range(1,len(part)-1):
                ids=[0,j,j+1]
                for weights in [np.array([1,1,1])/3,np.array([.1,.2,.7]),np.array([.6,.35,.05])]:
                    source_bary=weights@part[ids,3:]
                    original=source_bary@xyz
                    expected=[.1+np.clip(original[0]/2,0,1)*1.8,.6]
                    mapped=forward.apply(weights@native[ids])
                    np.testing.assert_allclose(mapped,expected,atol=1e-12,rtol=0)
                    self.assertAlmostEqual(float(weights@part[ids,2]),float(original[2]),places=12)
                    checks+=1
        self.assertGreater(checks,12)
        source_area=0.
        for part in [part for part,_ in pieces]+discarded:
            for j in range(1,len(part)-1):
                source_area+=abs(float(np.linalg.det(part[[0,j,j+1],3:])))
        self.assertAlmostEqual(source_area,1.,places=12)
        self.assertGreater(len(discarded),0)

if __name__=='__main__':unittest.main()

"""Keep the short collision landing between Tube's flat floor and its ramp."""
import gzip
import json
import numpy as np
import shapely
from shapely.affinity import affine_transform
from audit_all_map_gameplay_levels import OUT,ROOT,read,planes
from gameplay_standing_volumes import StandingVolumes,vertical_contacts
from build_all_map_gameplay_supports import navigation_triangles,standing_obstacles,plane_region
from compile_reviewed_svg_height_map import polygon,rings


def review():
    directory=OUT/'icebox';volumes=StandingVolumes('icebox')
    alignment=read(ROOT/'tactical-alignment-sides-v1/icebox.json');attack=np.array(alignment['nativeToAttackSvg'])
    native=(np.array([185.,225.])-attack[:,2])@np.linalg.inv(attack[:,:2]).T
    z,contact=volumes.physical_floor(native,4.7)
    assert contact=='/Port_BVPawn/BP_BlockingVolume166/Cube#0'
    index=next(i for i,r in enumerate(volumes.rows) if r['id']==contact);tri=volumes.triangles[index]
    heights,valid=vertical_contacts(tri,native)
    face=tri[np.flatnonzero(valid & (abs(heights-z)<1e-7))[0]]
    plane=np.linalg.solve(np.c_[face[:,:2],np.ones(3)],face[:,2])
    top=tri[np.max(abs(tri[:,:,2]-(tri[:,:,:2]@plane[:2]+plane[2])),axis=1)<1e-6]
    domain=shapely.union_all(shapely.polygons(top[:,:,:2]))
    nav=navigation_triangles('icebox');nav_shapes=shapely.polygons(nav[:,:,:2]);tree=shapely.STRtree(nav_shapes);coefficients=planes(nav)
    ids=[]
    for i in tree.query(domain,predicate='intersects'):
        p=domain.intersection(nav_shapes[i]).representative_point();xy=np.array([p.x,p.y])
        if abs(coefficients[i,:2]@xy+coefficients[i,2]-(plane[:2]@xy+plane[2]))<.6:ids.append(int(i))
    assert ids,'The landing needs independent walking navigation'
    domain=domain.intersection(shapely.union_all(nav_shapes[ids]).buffer(.42))
    domain=domain.difference(standing_obstacles(volumes,domain,z,ignored={index},floor_plane=plane))
    sid='icebox-tube-ramp-landing';evidence=[]
    for side in ['attack','defense']:
        path=directory/f'candidate-{side}.json.gz';model=read(path);model['supports']=[s for s in model['supports'] if s['id']!=sid]
        matrix=np.array(alignment[f'nativeTo{side.title()}Svg']);inverse=np.linalg.inv(matrix[:,:2])
        local_plane=np.r_[plane[:2]@inverse,plane[2]-(plane[:2]@inverse)@matrix[:,2]]
        svg=affine_transform(domain,[*matrix[0,:2],*matrix[1,:2],*matrix[:,2]])
        svg=svg.intersection(shapely.union_all([polygon(r) for r in model['receiver']]))
        for wall in model['walls']:
            for bottom,top in wall['bands']:
                low=-np.inf if bottom==0 else wall['floorElevationMeters']+bottom-model['defaultCameraHeightMeters']
                high=np.inf if top is None else wall['floorElevationMeters']+top-model['defaultCameraHeightMeters']
                svg=svg.difference(plane_region(polygon(wall),local_plane,low,high))
        encoded=[ring for part in shapely.get_parts(svg) if part.geom_type=='Polygon' for ring in rings(part)]
        assert encoded
        model['supports'].append(dict(id=sid,label='Tube ramp landing',rings=encoded,fillRule='evenodd',
            floorElevationMeters=0.,heightAboveFloorMeters=z,surfaceElevationMeters=z,surfacePlane=local_plane.tolist(),automaticStandingAllowed=True))
        path.write_bytes(gzip.compress(json.dumps(model,separators=(',',':'),allow_nan=False).encode(),mtime=0))
        evidence.append(dict(side=side,areaSvg=svg.area))
    report=dict(contact=contact,nativeMesh=volumes.rows[index]['nativeMesh'],nativeSurfacePlane=plane.tolist(),
        navigationTriangles=ids,knownPositionAttackSvg=[185.,225.],physicalFloorMeters=z,domains=evidence,
        reason='A short playable collision landing joins the Tube flat floor to its descending ramp. Sparse barycentric navigation sampling missed this body. The original walking navigation overlaps its exact top and the player capsule clears it.')
    (directory/'tube-landing-review.json').write_text(json.dumps(report,indent=2));print(json.dumps(report))


if __name__=='__main__':review()

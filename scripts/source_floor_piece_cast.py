"""Cast a floor interval without reconstructing a micrometre-length direction."""
import numpy as np
from audit_tactical_target_rays import ReferenceModel


def cast_floor_piece(source, origin_xy, direction_xy, distance, plane, lo, hi, eye_height=1.75):
    origin_xy=np.asarray(origin_xy);direction_xy=np.asarray(direction_xy);plane=np.asarray(plane)
    end_xy=origin_xy+direction_xy*distance
    start=np.r_[origin_xy,origin_xy@plane[:2]+plane[2]+eye_height]
    end=np.r_[end_xy,end_xy@plane[:2]+plane[2]+eye_height]
    scale=np.linalg.norm(end-start)/distance
    guards=dict(min_distance=lo*scale+(1e-5 if lo==0 else 0),
                end_padding=(distance-hi)*scale+(1e-5 if hi==distance else 0))
    if isinstance(source,ReferenceModel):
        guards['end_inclusive']=hi!=distance
    return source.cast(start,end,**guards)

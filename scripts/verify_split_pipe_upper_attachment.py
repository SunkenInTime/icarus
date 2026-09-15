"""Original-height pipe elbow/backing contacts and painted receiver exposure."""
import gzip
import json
from pathlib import Path

import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
import numpy as np
import shapely

from native_compact_wall_profiles import sha
from render_competing_floor_assemblies import clip_mesh_xy
from render_split_remaining_corner_families import sections
from tactical_alignment_receiver import receiver_domain
from verify_region_contact import segment_cells, interval_values
from verify_split_pipe_profile_proposal import mapper,REV


def line_union(lines):
    return shapely.union_all([shapely.LineString(line) for line in lines if not np.array_equal(line[0],line[1])])


def map_sections(family,lines):
    result=[]
    field=mapper(family)
    for line in lines:
        if np.array_equal(line[0],line[1]):
            result.append(field.apply(line));continue
        data=segment_cells(family,line)
        for start,end in zip(data[-1][:-1],data[-1][1:]):
            values=interval_values(data,start,end)
            assert np.linalg.norm(values-values[:1],axis=-1).max()<1e-7
            result.append(values[0])
    return np.asarray(result).reshape(-1,2,2)


def main():
    folder=REV/'split-pipe130-profile-region-proposal-v5'
    family=json.loads((folder/'region-declaration.json').read_text());field=mapper(family)
    packet_path=REV/'split-clove-pipe7479-review-v3/source-context.npz';p=np.load(packet_path)
    warp=json.loads(gzip.decompress((REV/'display-warps-v1/split.display-warp.json.gz').read_bytes()))
    matrix=np.column_stack([warp['projection']['axisU'],warp['projection']['axisV']]);origin=np.array(warp['projection']['origin'])
    objects=[7478,7479,7480,7481,7633,7634,7609]
    meshes={}
    retained=np.load(REV/'full-height-input-v1/split/source-correspondence.npz')['sourceFaces']
    membership=[]
    for obj in objects:
        ids=p['sourceFaceIds'][p['sourceObjectIds']==obj];raw=p['triangles'][p['sourceObjectIds']==obj].copy()
        keep=np.isin(ids,retained);membership.append(dict(object=obj,rawFaces=len(ids),retainedFaces=int(keep.sum())))
        raw=raw[keep];raw[:,:,:2]=raw[:,:,:2]@matrix.T+origin
        meshes[obj]=clip_mesh_xy(raw,np.array([233.,209.]),np.array([247.,229.]))
    art_path=Path('assets/maps/split_map.svg');receiver=receiver_domain(art_path)
    assert sha(art_path)==warp['art']['attack']['sha256']
    def_path=Path('assets/maps/split_map_defense.svg');defense=receiver_domain(def_path)
    assert sha(def_path)==warp['art']['defense']['sha256']
    reflection=np.asarray(warp['attackToDefenseSvg']['origin'])
    defense=shapely.transform(defense,lambda xy:reflection-xy)
    joint=shapely.union_all([receiver,defense])
    figures=[];rows=[]
    for z in [11.3,11.5,11.7,12.0]:
        source={obj:sections(tri,z)[0] for obj,tri in meshes.items()}
        mapped={obj:map_sections(family,lines) for obj,lines in source.items()}
        pipe_source=line_union(np.concatenate([source[obj] for obj in objects if obj!=7609]))
        wall_source=line_union(source[7609]);source_contacts=shapely.intersection(pipe_source,wall_source)
        pipe_mapped=line_union(np.concatenate([mapped[obj] for obj in objects if obj!=7609]))
        wall_mapped=line_union(mapped[7609]);mapped_contacts=shapely.intersection(pipe_mapped,wall_mapped)
        # The concerning tail is strictly past the131 endpoint atx240.797.
        # Clip lines exactly, then intersect the actual fill receiver, excluding
        # a1e-7 boundary arithmetic collar only in a separately reported metric.
        tail=shapely.intersection(pipe_mapped,shapely.box(240.797,209,248,229))
        exposed=shapely.intersection(tail,joint)
        interior=shapely.intersection(tail,joint.buffer(-1e-7))
        source_contact_points=shapely.get_coordinates(source_contacts)
        mapped_expected=field.apply(source_contact_points) if len(source_contact_points) else np.empty((0,2))
        distance_to_wall=shapely.distance(shapely.points(mapped_expected),wall_mapped) if len(mapped_expected) else np.array([])
        distance_to_pipe=shapely.distance(shapely.points(mapped_expected),pipe_mapped) if len(mapped_expected) else np.array([])
        row=dict(originalSourceHeightMeters=z,sourceContact=shapely.to_geojson(source_contacts),
            mappedContact=shapely.to_geojson(mapped_contacts),sourceContactPoints=len(source_contact_points),
            mappedSourceContactPoints=mapped_expected.tolist(),
            maximumMappedSourceContactToWallSvg=float(distance_to_wall.max(initial=0)),
            maximumMappedSourceContactToPipeSvg=float(distance_to_pipe.max(initial=0)),
            pipeSourceDistanceToBackingSvg=float(shapely.distance(pipe_source,wall_source)),
            pipeMappedDistanceToBackingSvg=float(shapely.distance(pipe_mapped,wall_mapped)),
            tailLengthSvg=float(tail.length),tailReceiverIntersectionLengthSvg=float(exposed.length),
            tailReceiverInteriorLengthSvg=float(interior.length),tailGeoJson=shapely.to_geojson(tail))
        assert distance_to_wall.max(initial=0)<1e-7 and distance_to_pipe.max(initial=0)<1e-7
        rows.append(row);figures.append((z,source,mapped))
    fig,axes=plt.subplots(2,4,figsize=(18,10))
    outline=shapely.intersection(joint,shapely.box(233,209,247,229))
    for i,(z,source,mapped) in enumerate(figures):
        for j,data in enumerate([source,mapped]):
            ax=axes[j,i]
            if j:
                for polygon in shapely.get_parts(outline):
                    if isinstance(polygon,shapely.Polygon):
                        xy=np.asarray(polygon.exterior.coords);ax.fill(*xy.T,color='#e5e7eb',alpha=.8)
                        for hole in polygon.interiors:ax.fill(*np.asarray(hole.coords).T,color='white')
            for obj,lines in data.items():
                for line in lines:ax.plot(*line.T,color='#2563eb' if obj==7609 else '#ea580c',lw=1.3)
            ax.plot([236.012,238.139,240.797,240.797],[213.64,216.298,216.298,229],color='black',ls='--',lw=1)
            ax.set_xlim(234,245);ax.set_ylim(222,210);ax.set_aspect('equal');ax.grid(alpha=.2)
            ax.set_title(('Original' if j==0 else 'Mapped, gray=painted receiver')+f' Z{z:g}m')
    fig.suptitle('Orange complete pipe/ports, blue retained original7609 backing\nEach section follows all region-cell crossings. Source heights unchanged; current proposal only.')
    fig.tight_layout();fig.savefig(folder/'upper-elbow-backing-receiver-context.png',dpi=170);plt.close(fig)
    result=dict(scope=__doc__,declarationSha256=sha(folder/'region-declaration.json'),sourcePacketSha256=sha(packet_path),
        attackSvgSha256=sha(art_path),defenseSvgSha256=sha(def_path),sourceMembership=membership,records=rows,
        scriptSha256=sha(Path(__file__)),productionMutation=False,
        limitations=['Four original-height sections; no full3D or all-observer visibility certification.',
                     'Receiver line overlap is reported literally; interior metric uses explicit1e-7SVG arithmetic collar.',
                     'No source profile, opacity, role or geometry changes.'])
    (folder/'upper-elbow-backing-receiver-review.json').write_text(json.dumps(result,indent=2)+'\n')
    print(json.dumps(result,indent=2))


if __name__=='__main__':main()

"""Cumulative diagnostic for the reviewed connected Mid source assemblies."""
import json
import argparse
from build_split_connected_tower import declarations, REV, bake
from declare_split_doorframe_region import declaration as doorway
from declare_split_component2_cover_region import declarations as body_and_cover
from declare_split_connected_mid_region import declaration as connected_mid
from declare_split_local_opening_frame_region import declaration as opening_frame


if __name__=='__main__':
    parser=argparse.ArgumentParser();parser.add_argument('--version',default='v22');parser.add_argument('--barriers',action='store_true');args=parser.parse_args()
    families,proof=declarations();body,cover=body_and_cover();mid=connected_mid()
    regions=[doorway(),body,cover,mid,opening_frame(mid)]
    if args.barriers:
        from declare_split_barrier_continuation_region import declaration as barriers
        regions.append(barriers())
    owned={face for region in regions for face in region['reviewedSourceFaces']}
    assert sum(len(region['reviewedSourceFaces']) for region in regions)==len(owned),'Overlapping region source ownership'
    for family in families:
        family['reviewedSourceFaces']=[face for face in family['reviewedSourceFaces'] if face not in owned]
    for region in regions:region['status']='Reviewed bounded diagnostic candidate; no production promotion.'
    families.extend(regions);proof['families']=families
    (REV/f'split-tower-connected-declarations-{args.version}.json').write_text(json.dumps(proof,indent=2))
    bake(out=REV/f'split-wall-family-normalized-candidate-{args.version}',extra_families=families)

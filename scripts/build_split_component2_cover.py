"""Cumulative V18 diagnostic with source-bound lower-cover registration."""
import json
from build_split_connected_tower import declarations,REV,bake
from declare_split_doorframe_region import declaration as doorway
from declare_split_component2_cover_region import declarations as body_and_cover

if __name__=='__main__':
    families,proof=declarations();body,cover=body_and_cover();regions=[doorway(),body,cover]
    owned={i for region in regions for i in region['reviewedSourceFaces']}
    for family in families:family['reviewedSourceFaces']=[i for i in family['reviewedSourceFaces'] if i not in owned]
    for region in regions:region['status']='Reviewed bounded diagnostic candidate; no production promotion.'
    families.extend(regions);proof['families']=families
    (REV/'split-tower-connected-declarations-v18.json').write_text(json.dumps(proof,indent=2))
    bake(out=REV/'split-wall-family-normalized-candidate-v18',extra_families=families)

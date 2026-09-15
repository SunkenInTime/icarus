"""Cumulative V20 diagnostic with the reviewed connected hostel/tower region."""
import json
from build_split_connected_tower import declarations, REV, bake
from declare_split_doorframe_region import declaration as doorway
from declare_split_component2_cover_region import declarations as body_and_cover
from declare_split_component7_catwalk_region import declaration as hostel_and_tower


if __name__ == '__main__':
    families, proof = declarations()
    body, cover = body_and_cover()
    regions = [doorway(), body, cover, hostel_and_tower()]
    owned = {face for region in regions for face in region['reviewedSourceFaces']}
    assert sum(len(region['reviewedSourceFaces']) for region in regions) == len(owned), 'Overlapping region ownership'
    for family in families:
        family['reviewedSourceFaces'] = [face for face in family['reviewedSourceFaces'] if face not in owned]
    for region in regions:
        region['status'] = 'Reviewed bounded diagnostic candidate; no production promotion.'
    families.extend(regions)
    proof['families'] = families
    (REV / 'split-tower-connected-declarations-v20.json').write_text(json.dumps(proof, indent=2))
    bake(out=REV / 'split-wall-family-normalized-candidate-v20', extra_families=families)

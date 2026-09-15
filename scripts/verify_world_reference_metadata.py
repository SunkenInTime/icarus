"""Verify supplemental floor metadata without changing the original 3D casts."""
from pathlib import Path

from complete_world_floor_alternatives import complete_reference, digest, read_json


def verify_floor_completion(reference_path, navigation_path):
    reference_path, navigation_path = Path(reference_path), Path(navigation_path)
    reference = read_json(reference_path)
    completion = reference.get('floorAlternativeCompletion')
    if completion is None:
        return []
    proof_path = (reference_path.parent / completion['proofFile']).resolve()
    if proof_path.parent != reference_path.parent.resolve() or digest(proof_path) != completion['proofSha256']:
        raise ValueError('Floor alternative proof changed or escaped its reference directory.')
    proof = read_json(proof_path)
    original_path, nav_path = Path(proof['sourceReference']), Path(proof['navigationFile'])
    if (proof.get('schemaVersion') != 1 or proof.get('map') != reference.get('map') or
            proof.get('raysAndStatisticsUnchanged') is not True or
            digest(original_path) != proof['sourceReferenceSha256'] or
            completion['sourceReferenceSha256'] != proof['sourceReferenceSha256'] or
            digest(nav_path) != proof['navigationSha256']):
        raise ValueError('Floor alternative source evidence changed.')
    expected_nav, actual_nav = read_json(nav_path), read_json(navigation_path)
    # Packing shortens native source paths. Every other field must be exact.
    for nav in (expected_nav, actual_nav):
        for record in nav.get('source', {}).get('files', []):
            record.pop('path', None)
    if expected_nav != actual_nav:
        raise ValueError('Floor alternative navigation differs from the asset.')
    original = read_json(original_path)
    replay, additions = complete_reference(original, expected_nav)
    annotated = {key: value for key, value in reference.items() if key != 'floorAlternativeCompletion'}
    if (replay != annotated or proof['additions'] != additions or
            proof['originsChecked'] != len(original['origins'])):
        raise ValueError('Reference metadata is not the exact native fallback completion.')
    original_policy = original_path.with_suffix('.policies.json')
    if digest(original_policy) != digest(reference_path.with_suffix('.policies.json')):
        raise ValueError('Floor metadata completion changed a material policy.')
    return [proof_path, original_path, nav_path, original_policy]

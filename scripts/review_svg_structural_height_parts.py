"""Include named structural parts that broad roof/sign/scenery filters omitted.

Only local sections of these declared assemblies contribute. Their names do not
supply a height, and source geometry never changes the authored XY footprint.
"""
import argparse
from functools import lru_cache
import json
from pathlib import Path
import shutil

import numpy as np

from audit_all_map_gameplay_levels import ROOT, read
from audit_assumed_svg_height_sections import clipped_height_intervals, merge_intervals, wall_stations
from resolve_local_svg_wall_profiles import OUTPUT, sha
from svg_review_source import source_world, verified_source_pack


PARTS = {
    'abyss': {
        'p1-stroke-2': ['Shell_6_BSiteWallADU/'],
    },
    'fracture': {
        'p1-fill-0': ['Shell_3_AsiteBackRadiator/'],
        'p1-fill-7': ['Pipe_0_Bend_1.001/'],
        'p7-stroke-3-p7-stroke-3-remainder-0': ['Shell_9_BSiteContaierDU/'],
        'p7-stroke-3-p7-stroke-3-remainder-1': ['Shell_9_BSiteContaierDU/'],
    },
    'breeze': {
        'p0-stroke-7': ['Shell_1_MidWallSlantedRoofB2/', 'Shell_1_MidWallSlantedRoofB3/'],
        'p0-stroke-15': ['TechElement_44_RollUpDoorA_0/'],
        'p0-stroke-0': ['Junk_1_ReinforcedPlateA_0/', 'Shell_0_ASiteBridgeB2/', 'Shell_0_ASiteCaveFacadeADU2/'],
        'p0-stroke-8': ['Shell_0_DefPathBRuinWallANew/'],
    },
    'bind': {
        'p2-fill-0': ['Kingdom_2_FenceStraight', 'Bmain_0_RollUpDoorA2/', 'Kingdom_0_DoorCDU/'],
        'p2-fill-6': ['RockCliff_3_ATK_Spawn_CenterRockWall_0/'],
        'p2-fill-5': ['RockCliff_3_ATKCave_0/'],
        'p2-fill-9': ['ASite_0_SecurityDoor_3/'],
        'p2-fill-3': ['Shell_0_BaseA/'],
    },
    'haven': {
        'p1-stroke-0': ['Roof_10_DragonSmall_0/', 'Wall_13_Garden_0/', 'WallTower_0_AtkSpawnBase_',
                        'Wall_19_SpawnShine_0/', 'Basalt_0_SingleChunkA_12/'],
    },
    'icebox': {
        'p8-stroke-1': ['Shell_2_WarehouseSignA/'],
        'p1-fill-0': ['Kingdom_0_DoorLargeB4/', 'Shell_6_SecurityTowerA2/', 'Shell_0_VistaWallFrameA/',
                      'ModernTech_6_FiltrationSystem/'],
        'p7-stroke-7': ['Shell_7_MidBuildingA/', 'Shell_7_MidBuildingBHallBack/'],
    },
    'lotus': {
        'p3-stroke-11': ['Tree_0_BanyanTreeTreeRoom_BP/'],
        'p3-stroke-0': ['DefSpawnWallA/', 'Rock_9_Rock_1_Jam2/', 'Shell_0_CSitePillarB4/',
                        'Shell_0_ASiteBackWallB/', 'Rock_9_Rock_2_Jam.001/'],
        'p3-stroke-4': ['Shell_0_AtkPathCWallRock/'],
        'p3-stroke-7': ['Shell_0_AtkPathATempleWallADU/'],
        'p3-stroke-9': ['ASiteBackArchRoofB/'],
    },
    'pearl': {
        'p7-stroke-4': ['Shell_0_BSiteK2BldgIntSideA/'],
        'p7-stroke-0': ['Sigin_0_ConstructionC/'],
        'p7-stroke-11': ['Shell_0_ASiteBldC/'],
    },
    'summit': {
        'p1-stroke-0-structural-3': ['PLUM_Props_Academy_MountainDisplay_Sign_01_A/',
                                   'PLUM_Shell_Blockout_SideB_BMain_Building03_A/'],
        'p1-stroke-3-structural-0': ['PLUM_Shell_Academy_BMainBuilding07_Wall01/'],
        'p1-stroke-0-structural-1': ['PLUM_Shell_Blockout_SideB_BSite_Building_2/'],
        'p1-stroke-10-structural-0': ['PLUM_Shell_Academy_BottomMidGate01_Wall02/'],
    },
}

PART_MATERIALS = {
    ('lotus', 3184): [
        '/Game/Environment/Jam/WorldMaterials/Vines/M0/Vines_0_M0_BigVinesMoss_MI',
        '/Game/Environment/Jam/Asset/Props/Tree/1/M0/Tree_1_M0_VistaTreeTrunkAMoss_MI',
    ],
}


def review(name, output=OUTPUT):
    directory = output / name
    path = directory / 'local-source-profiles.json'
    profiles = read(path)
    before = sha(path)
    backup = directory / f'profiles-before-structural-parts-{before[:12]}.json'
    if not backup.exists():
        shutil.copyfile(path, backup)
    source = source_world(name)
    source_metadata = read(source / 'geometry.json')
    metadata = source_metadata['objects']
    with np.load(source / 'geometry.npz') as data:
        points, faces = data['points'], data['faces']
        materials = data['material_indices']
    retained = verified_source_pack(name)['retained']
    matrix = np.asarray(read(ROOT / f'tactical-alignment-sides-v1/{name}.json')['nativeToAttackSvg'])
    inverse = np.linalg.inv(matrix[:, :2])
    inventory = {w['wallId']: w for w in read(directory / 'assumed-height-review.json')['records']}

    @lru_cache(maxsize=64)
    def geometry(oid):
        obj = metadata[oid]
        ids = np.arange(obj['firstFace'], obj['firstFace'] + obj['faceCount'])
        ids = ids[retained[ids]]
        if (name, oid) in PART_MATERIALS:
            packages = PART_MATERIALS[name, oid]
            selected_materials = [i for i, m in enumerate(source_metadata['materials'])
                                  if m.get('nativeMaterialPackage') in packages]
            if len(selected_materials) != len(packages):
                raise ValueError('Named structural material changed')
            ids = ids[np.isin(materials[ids], selected_materials)]
        return ids, points[faces[ids]].astype(float)

    changes = []
    for wall in profiles['records']:
        patterns = PARTS.get(name, {}).get(wall['wallId'])
        if patterns is None:
            continue
        object_ids = [i for i, o in enumerate(metadata) if any('/' + p in o['path'] for p in patterns)]
        if not object_ids:
            raise ValueError((name, wall['wallId'], 'Missing named structural assembly'))
        tangents = list(wall_stations(inventory[wall['wallId']]))
        for index, sample in enumerate(wall['stations']):
            center = np.array(sample['native'])
            tangent = inverse @ tangents[index][3]
            tangent /= np.linalg.norm(tangent)
            additions = []
            existing = {c['object'] for c in sample.get('sourceComponents', [])}
            for oid in object_ids:
                if oid in existing:
                    continue
                bounds = np.asarray(metadata[oid]['boundsMeters'])
                if np.any(bounds[0, :2] > center + 1.) or np.any(bounds[1, :2] < center - 1.):
                    continue
                ids, tri = geometry(oid)
                selected, bands = clipped_height_intervals(tri, center, tangent, .15, .85, include_flat=True)
                if len(selected):
                    additions.append(dict(object=oid, path=metadata[oid]['path'], role='declared-structural-part',
                                          faces=ids[selected].tolist(), bands=merge_intervals(bands)))
            if not additions:
                continue
            previous = sample.get('measuredTopMeters')
            components = [*sample.get('sourceComponents', []), *additions]
            bands = merge_intervals([*sample.get('sourceBands', []), *[b for c in additions for b in c['bands']]])
            top = max(hi for _, hi in bands)
            sample.update(status='measured-facade', sourceComponents=components,
                sourceFaces=[f for c in components for f in c['faces']], sourceBands=bands,
                measuredBottomMeters=min(lo for lo, hi in bands), measuredTopMeters=top,
                declaredStructuralPartEvidence=dict(patterns=patterns, addedObjects=[c['object'] for c in additions]))
            if not sample.get('sourceObject'):
                sample.update(sourceObject=additions[0]['object'], sourcePath=additions[0]['path'])
            passage = sample.get('passageIntervalMeters')
            if passage and any(lo < passage[1] and hi > passage[0] for c in additions for lo, hi in c['bands']):
                sample.pop('passageIntervalMeters')
                sample['previousPassageInvalidatedByStructuralPart'] = passage
            changes.append(dict(wallId=wall['wallId'], station=index, previousTopMeters=previous,
                                topMeters=top, addedObjects=[c['object'] for c in additions]))
    profiles.setdefault('structuralPartReviews', []).append(dict(algorithmSha256=sha(Path(__file__)),
        inputProfilesSha256=before, inputProfilesFile=backup.name, changes=changes))
    path.write_text(json.dumps(profiles, separators=(',', ':')))
    print(name, 'structural sections', len(changes), flush=True)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('maps', nargs='*', default=list(PARTS))
    for name in parser.parse_args().maps:
        review(name)

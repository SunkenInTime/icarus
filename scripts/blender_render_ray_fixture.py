"""Render geometric sightline fixtures from the exact scene used by the rays.

Run in Blender with the audited .blend open. Neutral shading and an orange hit
object expose geometry; these are test cameras, not captures from Valorant.
"""
import argparse
import hashlib
import json
from pathlib import Path
import sys

import bpy
from mathutils import Vector


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--rays', required=True)
    parser.add_argument('--ray-ids', required=True, nargs='+')
    parser.add_argument('--output', required=True)
    args = parser.parse_args(sys.argv[sys.argv.index('--') + 1:])
    report = json.loads(Path(args.rays).read_text(encoding='utf-8'))
    scene_hash = hashlib.sha256(Path(bpy.data.filepath).read_bytes()).hexdigest()
    if scene_hash != report['referenceSha256']:
        raise ValueError('The scene does not match the ray reference fingerprint.')
    rays = {r['id']: r for r in report['rays']}
    chosen = [rays[i] for i in args.ray_ids]
    output = Path(args.output)
    output.mkdir(parents=True, exist_ok=True)
    scene = bpy.context.scene
    scene.render.engine = 'BLENDER_WORKBENCH'
    scene.display.shading.color_type = 'OBJECT'
    for obj in scene.objects:
        obj.color = (0.52, 0.62, 0.68, 1)
    first_hit = chosen[0]['objectIndex']
    if first_hit is not None:
        owner = report['objects'][first_hit]
        obj = bpy.data.objects.get(owner['mesh'])
        if obj is None:
            raise ValueError('The recorded blocking mesh is absent.')
        obj.color = (1, 0.35, 0.04, 1)
    camera = scene.camera
    camera.data.type = 'PERSP'
    camera.data.lens = 20
    camera.data.clip_start = 0.025
    scene.render.resolution_x = 1280
    scene.render.resolution_y = 720
    scene.render.resolution_percentage = 100
    scene.render.image_settings.file_format = 'PNG'
    for ray in chosen:
        camera.location = Vector(ray['startMeters'])
        direction = Vector(ray['endMeters']) - camera.location
        camera.rotation_euler = direction.to_track_quat('-Z', 'Y').to_euler()
        scene.render.filepath = str(output / (ray['id'] + '.png'))
        bpy.ops.render.render(write_still=True)
    (output / 'fixture.json').write_text(json.dumps({
        'status': 'geometric-camera-fixture', 'gameplayVerified': False,
        'referenceSha256': scene_hash,
        'raysSha256': hashlib.sha256(Path(args.rays).read_bytes()).hexdigest(),
        'shading': 'Neutral geometry; first ray blocking object highlighted orange.',
        'cameraLensMm': camera.data.lens,
        'cameraHeightsAreTestParameters': True, 'rays': chosen,
    }, indent=2), encoding='utf-8')


if __name__ == '__main__':
    main()

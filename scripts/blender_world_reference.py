"""Load an exported USD in Blender, save a reusable scene and a proof render.

blender --background --factory-startup --python scripts/blender_world_reference.py -- WORLD.usda OUTPUT_DIR
No hand-drawn map geometry is used to construct this scene.
"""
import argparse
from collections import Counter
import json
from pathlib import Path
import sys
import time

import bpy
from mathutils import Vector


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('source')
    parser.add_argument('output')
    parser.add_argument('--name', default='split')
    parser.add_argument('--no-render', action='store_true')
    parser.add_argument('--keep-scene', action='store_true',
                        help='Use only in an already empty scene with an active UI context.')
    args = parser.parse_args(sys.argv[sys.argv.index('--') + 1:])
    out = Path(args.output).resolve()
    out.mkdir(parents=True, exist_ok=True)
    source = Path(args.source).resolve(strict=True)
    if not args.keep_scene:
        bpy.ops.wm.read_factory_settings(use_empty=True)
    start = time.perf_counter()
    bpy.ops.wm.usd_import(filepath=str(source), import_visible_only=True,
                          import_lights=False, import_cameras=False,
                          import_volumes=False, import_curves=False,
                          import_points=False, import_shapes=False,
                          support_scene_instancing=True,
                          import_textures_mode='IMPORT_NONE',
                          apply_unit_conversion_scale=True)
    elapsed = time.perf_counter() - start
    scene = bpy.context.scene
    depsgraph = bpy.context.evaluated_depsgraph_get()
    instance_count = 0
    bounds = []
    for instance in depsgraph.object_instances:
        if instance.object.type == 'MESH':
            instance_count += 1
            bounds.extend(instance.matrix_world @ Vector(corner)
                          for corner in instance.object.bound_box)
    minimum = Vector(tuple(min(p[j] for p in bounds) for j in range(3)))
    maximum = Vector(tuple(max(p[j] for p in bounds) for j in range(3)))
    report = {'source': str(source), 'importSeconds': elapsed,
              'blenderVersion': bpy.app.version_string,
              'objectTypes': dict(Counter(o.type for o in scene.objects)),
              'evaluatedMeshOccurrences': instance_count, 'materials': len(bpy.data.materials),
              'images': len(bpy.data.images),
              'missingImages': [i.filepath for i in bpy.data.images if i.source == 'FILE' and not i.packed_file and not Path(bpy.path.abspath(i.filepath)).is_file()],
              'boundsMeters': [list(minimum), list(maximum)],
              'status': 'scene-imported-not-gameplay-certified'}
    (out / 'blender-import.json').write_text(json.dumps(report, indent=2), encoding='utf-8')
    print('ICARUS_IMPORT_REPORT ' + json.dumps(report), flush=True)
    # Initial overview; the playable area is much smaller than sky/vista bounds.
    # These are camera settings only, not modifications of game geometry.
    target = Vector((25, 44, 4))
    bpy.ops.object.camera_add(location=(120, -85, 175))
    camera = bpy.context.object
    camera.name = 'Icarus_Audit_Camera'
    camera.rotation_euler = (target - camera.location).to_track_quat('-Z', 'Y').to_euler()
    camera.data.type = 'ORTHO'
    camera.data.ortho_scale = 170
    camera.data.clip_end = 3000
    scene.camera = camera
    scene.render.engine = 'BLENDER_WORKBENCH'
    scene.display.shading.light = 'STUDIO'
    scene.display.shading.color_type = 'SINGLE'
    scene.display.shading.single_color = (0.52, 0.62, 0.68)
    scene.display.shading.show_shadows = True
    scene.display.shading.show_cavity = True
    scene.display.shading.cavity_type = 'BOTH'
    scene.display.shading.background_type = 'WORLD'
    scene.world = bpy.data.worlds.new('Icarus_Audit_Background')
    scene.world.color = (0.015, 0.022, 0.035)
    scene.render.resolution_x = 1920
    scene.render.resolution_y = 1080
    scene.render.resolution_percentage = 100
    scene.render.image_settings.file_format = 'PNG'
    scene.render.filepath = str(out / f'{args.name}-overview.png')
    for area in bpy.context.screen.areas if bpy.context.screen else []:
        if area.type == 'VIEW_3D':
            area.spaces.active.region_3d.view_perspective = 'CAMERA'
            area.spaces.active.shading.type = 'SOLID'
            area.spaces.active.shading.color_type = 'SINGLE'
            area.spaces.active.shading.single_color = (0.52, 0.62, 0.68)
            area.spaces.active.overlay.show_overlays = False
            area.spaces.active.region_3d.view_camera_zoom = 8
    bpy.ops.wm.save_as_mainfile(filepath=str(out / f'{args.name}-reference.blend'))
    if not args.no_render:
        bpy.ops.render.render(write_still=True)


if __name__ == '__main__':
    main()

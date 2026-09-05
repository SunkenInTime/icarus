"""Open Blender empty, then import and orbit a real USD scene for recording.

Launch without --background. Create OUTPUT/start-recording after your window
recorder is ready. That trigger starts the actual import, followed by a live
camera orbit. This script does not synthesize or accelerate loading footage.
"""
import argparse
import importlib.util
import math
from pathlib import Path
import sys
import time

import bpy
from mathutils import Vector


parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('source')
parser.add_argument('output')
args = parser.parse_args(sys.argv[sys.argv.index('--') + 1:])
out = Path(args.output).resolve()
out.mkdir(parents=True, exist_ok=True)
bpy.ops.wm.read_factory_settings(use_empty=True)
(out / 'recorder-ready').write_text('Blender is ready for window recording.', encoding='utf-8')
start = None


def orbit():
    elapsed = time.perf_counter() - start
    angle = math.radians(-70 + 30 * min(1, elapsed / 18))
    camera = bpy.context.scene.camera
    target = Vector((25, 44, 4))
    camera.location = target + Vector((math.cos(angle) * 160, math.sin(angle) * 160, 170))
    camera.rotation_euler = (target - camera.location).to_track_quat('-Z', 'Y').to_euler()
    for window in bpy.context.window_manager.windows:
        window.workspace.status_text_set('ICARUS | Split static art | Geometry diagnostic, materials unresolved')
        for area in window.screen.areas:
            if area.type == 'VIEW_3D':
                space = area.spaces.active
                space.region_3d.view_perspective = 'CAMERA'
                space.region_3d.view_camera_zoom = 8
                space.shading.type = 'SOLID'
                space.shading.color_type = 'SINGLE'
                space.shading.single_color = (0.52, 0.62, 0.68)
                space.overlay.show_overlays = False
                area.tag_redraw()
    return 1 / 30 if elapsed < 25 else None


def wait_for_recording():
    global start
    if not (out / 'start-recording').is_file():
        return 0.25
    if bpy.context.workspace:
        bpy.context.workspace.status_text_set('ICARUS | Importing Split USD geometry')
    helper = Path(__file__).with_name('blender_world_reference.py')
    spec = importlib.util.spec_from_file_location('world_reference', helper)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    sys.argv = [str(helper), '--', args.source, str(out), '--name', 'split-recording',
                '--no-render', '--keep-scene']
    module.main()
    (out / 'import-finished').write_text(str(time.time()), encoding='utf-8')
    start = time.perf_counter()
    bpy.app.timers.register(orbit, first_interval=0.1)
    return None


bpy.app.timers.register(wait_for_recording, first_interval=1)

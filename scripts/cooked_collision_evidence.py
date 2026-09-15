"""Inspect the simple-shape inventory in extracted UE 5.3 Chaos payloads.

ChaosDerivedData.cpp serializes float precision, SimpleImplicits, then
ComplexImplicits. An empty SimpleImplicits array can be proven without decoding
the following triangle mesh. Nonempty arrays stay unresolved here.
"""
import hashlib
import json
from pathlib import Path
import struct

COOKER_SOURCE = ('https://github.com/chenyong2github/UnrealEngine/blob/'
    'c865e168d0935b8e5f4bd865ddcc1c733c8ce7cf/'
    'Engine/Source/Runtime/Engine/Private/PhysicsEngine/Experimental/ChaosDerivedData.cpp#L108')


def empty_simple_shapes(data):
    if len(data) < 12:
        raise ValueError('Truncated Chaos collision payload')
    precision, simple_count, complex_count = struct.unpack_from('<iii', data)
    if precision != 4 or simple_count != 0:
        return False
    if complex_count == 0:
        # Fully empty UE 5.3 record: precision; simple and complex arrays;
        # UV index, position and channel arrays; then face-remap array.
        # Require the complete record rather than accepting a short header.
        return data == struct.pack('<7i', 4, 0, 0, 0, 0, 0, 0)
    if complex_count != 1 or len(data) < 21:
        return False
    exists, tag = struct.unpack_from('<ii', data, 12)
    return exists == 1 and tag == 0 and data[20] == 11


def no_simple_collision(root, mesh_path, body, additional_exports=()):
    if any(body.get('AggGeom', {}).values()):
        return None
    paths = [p for p in Path(mesh_path).parents if p.name == 'properties']
    if len(paths) != 1:
        return None
    relative = Path(mesh_path).relative_to(paths[0])
    exports = [*additional_exports, *[root/name for name in [
        'icebox-all-collision-v2', 'icebox-all-collision-v1', 'icebox-expanded-collision-v1', 'icebox-acceptance-collision-v2']]]
    export = next((path for path in exports if (path/'properties'/relative).exists()), None)
    if export is None:
        return None
    config_path = export / 'collision-configuration.json'
    exported_mesh = export / 'properties' / relative
    if not exported_mesh.exists():
        return None
    # Collision bytes and previously verified render placement must describe
    # the same mesh revision.
    if exported_mesh.read_bytes() != Path(mesh_path).read_bytes():
        raise ValueError('Cooked collision export differs from the audited mesh')
    config = json.loads(config_path.read_bytes())
    complexity = None
    for source in config:
        for line in source['lines']:
            if line.startswith('DefaultShapeComplexity='):
                complexity = line.split('=', 1)[1].strip()
    flag = body.get('CollisionTraceFlag', '').split('::')[-1]
    if flag in ['', 'CTF_UseDefault']:
        flag = complexity
    if flag not in ['CTF_UseSimpleAndComplex', 'CTF_UseSimpleAsComplex']:
        return None
    folder = export / 'collision' / relative.with_suffix('')
    index = folder / 'index.json'
    # The extractor emits no index when the mesh has no cooked records.
    # Missing evidence cannot establish an empty simple-shape inventory.
    if not index.exists():
        bodies_path = folder / 'bodies.json'
        if bodies_path.exists():
            bodies = json.loads(bodies_path.read_bytes())
            source_bodies = [r for r in json.loads(Path(mesh_path).read_bytes()) if r.get('Type') == 'BodySetup']
            if (len(source_bodies) == 1 and
                    bodies == [dict(body=source_bodies[0]['Name'], formats=[])]):
                return dict(reason='No aggregate primitives and the extracted body has no cooked collision formats.',
                    resolvedComplexity=flag, bodyInventorySha256=hashlib.sha256(bodies_path.read_bytes()).hexdigest(),
                    configurationSha256=hashlib.sha256(config_path.read_bytes()).hexdigest(), source=COOKER_SOURCE)
        return None
    records = json.loads(index.read_bytes())
    if len(records) != 1 or records[0]['format'] != 'PhysXPC':
        return None
    record = records[0]
    data = (folder / record['file']).read_bytes()
    if len(data) != record['bytes'] or hashlib.sha256(data).hexdigest() != record['sha256']:
        raise ValueError('Cooked collision bytes changed after extraction')
    if not empty_simple_shapes(data):
        return None
    return dict(reason='No aggregate primitives or cooked simple implicits; project uses simple player collision.',
        resolvedComplexity=flag, cookedSha256=record['sha256'],
        configurationSha256=hashlib.sha256(config_path.read_bytes()).hexdigest(),
        source=COOKER_SOURCE,
        uvSerializationSource='https://github.com/chenyong2github/UnrealEngine/blob/c865e168d0935b8e5f4bd865ddcc1c733c8ce7cf/Engine/Source/Runtime/Engine/Classes/PhysicsEngine/BodySetup.h#L50')

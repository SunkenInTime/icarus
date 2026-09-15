"""Resolve supplemented mesh identities from their recorded native component."""
import hashlib
from pathlib import Path

import numpy as np
from native_collision_defaults import resolve_template


def supplement_placement(obj, read, verify, template_roots=()):
    evidence = obj.get('nativeResolvedComponent')
    if evidence is None:
        return None
    source = Path(evidence['source'])
    verify(str(source), evidence['sourceSha256'])
    records = [row for row in read(str(source)) if row['exportIndex'] == evidence['exportIndex']]
    if len(records) != 1 or any(records[0].get(key) != evidence.get(key)
                               for key in ['name', 'path', 'mesh', 'template']):
        raise ValueError('Supplement native component record differs from its source')
    component_root = next(parent for parent in source.parents if parent.name == 'components')
    relative = source.relative_to(component_root)
    native_level = component_root.parent/'properties'/relative
    extraction_path = component_root.parent/'extraction-audit.json'
    extraction = read(str(extraction_path))
    packages = {relative.with_suffix(extension).as_posix() for extension in ['.uasset', '.umap']}
    exports = [row for row in extraction['properties'] if row['packagePath'] in packages]
    if len(exports) != 1 or exports[0].get('errors') != 0 or 'sha256' not in exports[0]:
        raise ValueError('Supplement native level lacks a successful extraction record')
    verify(str(native_level), exports[0]['sha256'])
    level = read(str(native_level))
    component = level[evidence['exportIndex']]
    if component['Name'] != evidence['name']:
        raise ValueError('Supplement component index identifies a different object')
    actor_index = int(component['Outer']['ObjectPath'].rsplit('.', 1)[1])
    actor = level[actor_index]
    actors = obj['sourceActorEvidence']
    if len(actors) != 1 or actors[0]['name'] != actor['Name']:
        raise ValueError('Supplement component belongs to a different source actor')
    mesh = component.get('Properties', {}).get('StaticMesh')
    template_evidence = []
    if mesh is None and component.get('Template') == evidence.get('template'):
        resolved, template_evidence = resolve_template(component, template_roots)
        mesh = resolved.get('Properties', {}).get('StaticMesh')
    if mesh != evidence['mesh']:
        raise ValueError('Supplement native mesh differs from its component reference')
    matrix = np.asarray(obj['sourceWorldTransform'])
    if matrix.shape != (4, 4) or not np.all(np.isfinite(matrix)):
        raise ValueError('Supplement source transform is invalid')
    instance = obj.get('sourceInstanceIndex')
    if '/Prototypes/' in obj['primPath']:
        if not isinstance(instance, int) or obj['path'] != f"{obj['primPath']}/Instance_{instance}":
            raise ValueError('Supplement instance identity is missing or inconsistent')
    elif instance is not None:
        raise ValueError('Supplement instance lacks a prototype')
    # The collider loader must still compare this USD transform and mesh with
    # the recorded world triangles before using any physical collision shape.
    return dict(path=obj['path'], firstFace=obj['firstFace'], faceCount=obj['faceCount'],
        nativeLevel=str(native_level), nativeLevelSha256=exports[0]['sha256'],
        nativeComponentIndex=evidence['exportIndex'], nativeActor=actor['Name'],
        nativeMesh=mesh['ObjectPath'].rsplit('.', 1)[0], sourcePrim=obj['primPath'],
        sourceInstance=instance if instance is not None else 0, sourceUsd=obj['sourceLevel'],
        placementDeterminant=float(np.linalg.det(matrix[:3, :3])),
        supplementIdentity=dict(componentSource=str(source), componentSourceSha256=evidence['sourceSha256'],
            extractionSha256=hashlib.sha256(extraction_path.read_bytes()).hexdigest(),
            templateEvidence=template_evidence))

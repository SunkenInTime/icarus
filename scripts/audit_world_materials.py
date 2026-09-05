"""Trace USD face bindings to the extracted material JSON, including overrides.

Requires usd-core. A preview shader is not an authoritative opacity test.
This inventories surfaces that need shader-aware verification before ray hits
can be accepted as sightline blockers. Game assets remain local.
"""
import argparse
from collections import Counter
import hashlib
import json
from pathlib import Path

from pxr import Usd, UsdGeom, UsdShade


def digest(path):
    with Path(path).open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def audit(source, output):
    stage = Usd.Stage.Open(str(Path(source).resolve(strict=True)))
    materials, bindings, issues = {}, [], []

    def material_record(material):
        key = str(material.GetPath())
        if key in materials:
            return key
        # The referenced Material prim comes from its own USD file. Resolve
        # through composition, so actor overrides beat the mesh's base material.
        candidates = []
        for spec in material.GetPrim().GetPrimStack():
            path = Path(spec.layer.realPath).with_suffix('.json')
            if path.is_file() and spec.typeName == 'Material':
                data = json.loads(path.read_text(encoding='utf-8-sig'))
                if isinstance(data, dict) and 'Parameters' in data:
                    candidates.append((path, data))
        if not candidates:
            materials[key] = {'source': None, 'category': 'unresolved'}
            issues.append({'kind': 'missing-material-json', 'material': key})
            return key
        path, data = candidates[0]
        params = data['Parameters']
        blend = params.get('BlendMode')
        category = 'opaque' if blend == 0 else 'masked' if blend == 1 else 'shader-dependent'
        root = next(p for p in path.parents if p.name == 'Content')
        missing, resolved_textures = [], {}
        for texture in set(data.get('Textures', {}).values()):
            if texture.startswith('/Game/'):
                file = (root / texture[6:].split('.')[0]).with_suffix('.png')
            elif texture.startswith('/Engine/'):
                file = (root.parent.parent / 'Engine' / 'Content' / texture[8:].split('.')[0]).with_suffix('.png')
            else:
                issues.append({'kind': 'unresolved-texture-path', 'material': key, 'texture': texture})
                continue
            # Floating-point textures and cubemaps are exported as HDR even
            # when ordinary textures use PNG. Preserve that format distinction.
            actual = next((p for p in [file, file.with_suffix('.hdr')] if p.is_file()), None)
            if actual is None:
                missing.append(str(file))
            else:
                resolved_textures[texture] = str(actual)
        shader = material.GetPrim().GetChild('PBRShader')
        opacity = shader.GetAttribute('inputs:opacity') if shader else None
        authored_opacity = bool(opacity and (opacity.HasAuthoredValueOpinion() or opacity.GetConnections()))
        materials[key] = {
            'source': str(path), 'sourceSha256': digest(path),
            'category': category, 'blendMode': blend,
            'usdHasOpacityInput': authored_opacity,
            'missingTextures': missing,
            'resolvedTextures': resolved_textures,
        }
        if blend is None:
            issues.append({'kind': 'missing-blend-mode', 'material': key})
        for file in missing:
            issues.append({'kind': 'missing-texture', 'material': key, 'file': file})
        return key

    mesh_count = 0
    for prim in stage.Traverse():
        if not prim.IsA(UsdGeom.Mesh):
            continue
        mesh = UsdGeom.Mesh(prim)
        if mesh.ComputeVisibility() == UsdGeom.Tokens.invisible:
            continue
        mesh_count += 1
        faces = mesh.GetFaceVertexCountsAttr().Get() or []
        if not faces:
            issues.append({'kind': 'empty-mesh', 'mesh': str(prim.GetPath())})
        assigned = set()
        subsets = UsdShade.MaterialBindingAPI(prim).GetMaterialBindSubsets()
        for subset in subsets:
            indices = list(subset.GetIndicesAttr().Get() or [])
            if not indices:
                continue
            if (len(set(indices)) != len(indices) or
                    any(i < 0 or i >= len(faces) for i in indices) or assigned.intersection(indices)):
                issues.append({'kind': 'invalid-or-overlapping-material-subset', 'mesh': str(prim.GetPath())})
                continue
            assigned.update(indices)
            material = UsdShade.MaterialBindingAPI(subset.GetPrim()).ComputeBoundMaterial()[0]
            if not material:
                issues.append({'kind': 'unbound-subset', 'path': str(subset.GetPath())})
                continue
            key = material_record(material)
            bindings.append({'mesh': str(prim.GetPath()), 'subset': str(subset.GetPath()),
                             'material': key, 'faces': len(indices),
                             'triangles': sum(max(0, faces[i] - 2) for i in indices)})
        rest = set(range(len(faces))) - assigned
        if rest:
            material = UsdShade.MaterialBindingAPI(prim).ComputeBoundMaterial()[0]
            if material:
                key = material_record(material)
                bindings.append({'mesh': str(prim.GetPath()), 'subset': None, 'material': key,
                                 'faces': len(rest), 'triangles': sum(max(0, faces[i] - 2) for i in rest)})
            else:
                issues.append({'kind': 'unbound-faces', 'mesh': str(prim.GetPath()), 'faces': len(rest)})
    if not mesh_count:
        issues.append({'kind': 'no-visible-meshes'})
    counts = Counter()
    for row in bindings:
        counts[materials[row['material']]['category']] += row['triangles']
    sources = {m['source']: m for m in materials.values() if m['source']}
    summary = {'visibleMeshPrimsIncludingPrototypes': mesh_count,
               'materialBindings': len(bindings), 'uniqueSourceMaterials': len(sources),
               'sourceMaterialsByCategory': dict(Counter(m['category'] for m in sources.values())),
               'trianglesBeforeInstancerExpansionByCategory': dict(counts),
               'nonOpaqueMaterialPrimsWithoutUsdOpacity': sum(
                   m['category'] != 'opaque' and not m.get('usdHasOpacityInput', False)
                   for m in materials.values()),
               'issues': len(issues)}
    result = {'schemaVersion': 1, 'status': 'binding-issues' if issues else 'material-bindings-resolved',
              'gameplayVerified': False, 'source': str(Path(source).resolve()),
              'sourceSha256': digest(source), 'summary': summary,
              'materials': materials, 'bindings': bindings, 'issues': issues,
              'limitations': ['Opaque is a parsed blend mode, not proof of gameplay visibility.',
                              'Masked and translucent surfaces require original shader semantics.',
                              'USD preview opacity may omit or approximate the original shader.',
                              'Triangle counts include prototypes, before placed-instance expansion.']}
    Path(output).write_text(json.dumps(result, indent=2), encoding='utf-8')
    print(json.dumps(summary))
    return not issues


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('source')
    parser.add_argument('output')
    args = parser.parse_args()
    raise SystemExit(0 if audit(args.source, args.output) else 1)

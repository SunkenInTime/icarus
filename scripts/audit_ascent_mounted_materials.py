"""Bind the reviewed mounted assemblies to raw native materials and pack scope."""
import hashlib
import json
from pathlib import Path

import numpy as np
from PIL import Image

ROOT = Path('E:/IcarusWorldAudit/2026-09-06')
REV = ROOT / 'tactical-visibility-revision'
OUT = REV / 'ascent-mounted-material-review-v1'


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    geometry = ROOT / 'supplemented-v2/world/ascent/geometry.npz'
    metadata_path = geometry.with_suffix('.json')
    metadata = json.loads(metadata_path.read_text())
    raw = np.load(geometry)
    material_ids = raw['material_indices']
    source_ids_path = REV / 'full-height-input-v1/ascent/source-correspondence.npz'
    retained = np.load(source_ids_path)['sourceFaces']
    is_retained = np.zeros(len(raw['faces']), dtype=bool)
    is_retained[retained] = True
    policy_path = ROOT / 'reference-world-final-validated/ascent.policies.json'
    policies = json.loads(policy_path.read_text())['policies']
    rows = []
    for oid in [857, 858, *range(1041, 1049), 6571, 769]:
        obj = metadata['objects'][oid]
        ids = np.arange(obj['firstFace'], obj['firstFace'] + obj['faceCount'])
        materials = []
        for mid in np.unique(material_ids[ids]):
            selected = ids[material_ids[ids] == mid]
            materials.append(dict(materialIndex=int(mid), material=metadata['materials'][mid],
                                  policy=policies[mid], originalFaces=selected.tolist(),
                                  retainedOriginalFaces=selected[is_retained[selected]].tolist(),
                                  omittedOriginalFaces=selected[~is_retained[selected]].tolist()))
        rows.append(dict(object=oid, path=obj['path'], sourceFaces=len(ids),
                         retainedFaces=int(is_retained[ids].sum()), materials=materials))
    native_root = OUT / 'native/properties/ShooterGame/Content'
    instance_path = native_root / 'Environment/Asset/WorldMaterials/Glass/M0/GlassWarped_M0E_MI.json'
    texture_path = native_root / 'Environment/Asset/WorldMaterials/Glass/M0/Glass_M0_DF.json'
    parent_path = OUT / 'native-parent/properties/ShooterGame/Content/Environment/Materials/BaseMats/EnvBaseMat/BaseEnv_MAT_V4.json'
    instance = json.loads(instance_path.read_text())[0]
    parent = json.loads(parent_path.read_text())[0]
    component_path = ROOT / 'native-material-audit/resolved-component-export/properties/ShooterGame/Content/Maps/Ascent/Ascent_Art_Atk.json'
    components = json.loads(component_path.read_text())
    meshes = ('Door_0_Books.', 'Papers_0_AntiKingdomB.', 'Papers_0_AntiKingdomD.',
              'Papers_0_AntiKingdomPosterB.', 'Windows_9_Books.', 'Conduit_1_Plain.')
    selected_components = []
    for record in components:
        p = record.get('Properties', {})
        mesh = p.get('StaticMesh', {}).get('ObjectPath', '')
        if not any(name in mesh for name in meshes):
            continue
        selected_components.append(dict(name=record['Name'], outer=record.get('Outer'),
            type=record['Type'], mesh=mesh, properties={k:p[k] for k in
            ['RelativeLocation','RelativeRotation','RelativeScale3D','Mobility','CreationMethod',
             'BodyInstance','OverrideMaterials','PerInstanceSMData','bUseDefaultCollision'] if k in p}))
    texture_png = Path(metadata['materials'][4776]['source']).with_name('Glass_M0_DF.png')
    alpha = np.asarray(Image.open(texture_png).convert('RGBA'))[:, :, 3]
    values, counts = np.unique(alpha, return_counts=True)
    frozen_audit = json.loads((REV/'null-native-all-base-export-v1/extraction-audit.json').read_text())
    native_audits = [json.loads((OUT/name/'extraction-audit.json').read_text()) for name in ['native','native-parent']]
    for audit in native_audits:
        assert audit['archives'] == frozen_audit['archives']
        assert audit['mapping'] == frozen_audit['mapping']
        assert audit['errorEntries'] == 0
    report = dict(schemaVersion=1, productionMutation=False,
        sourceHashes=dict(geometry=sha(geometry), metadata=sha(metadata_path), policies=sha(policy_path),
                          sourceCorrespondence=sha(source_ids_path), components=sha(component_path)),
        objects=rows, nativeComponents=selected_components,
        glass=dict(instance=instance, instanceSha256=sha(instance_path), parentProperties=parent['Properties'],
                   parentSha256=sha(parent_path), texturePropertiesSha256=sha(texture_path),
                   texturePngSha256=sha(texture_png), textureAlpha=[dict(value=int(v),pixels=int(n)) for v,n in zip(values,counts)],
                   textureAlphaNormalizedRange=[float(alpha.min()/255),float(alpha.max()/255)],
                   sourceScope='Eight glass triangles omitted, four per static door instance. Opaque door frame/panel faces remain in the full pack.',
                   finding='The native instance explicitly overrides blend mode to TranslucentGreyTransmittance. Its bound diffuse texture has alpha215–216/255. The exported USD preview connects that alpha to opacity. The cooked native export exposes parameters but not the full opacity expression graph, so the exact in-game transmittance has not been reconstructed.',
                   decision='Keep the current material policy unchanged. This evidence does not establish a missing opaque wall, and does not certify a gameplay opening. Preserve the mounted poster alpha masks and static door frame profiles during registration.'),
        nativeArchiveAndMappingHashesMatchFrozenAudit=True,
        scope='Source material and retention audit only. Native collision flags are recorded, not used to infer visual opacity. No gameplay or complete shader evaluation claim.')
    (OUT/'review.json').write_text(json.dumps(report,indent=2)+'\n')
    print(json.dumps(dict(objects=[dict(object=r['object'],source=r['sourceFaces'],retained=r['retainedFaces']) for r in rows],glass=report['glass']['finding']),indent=2))


if __name__ == '__main__':
    main()

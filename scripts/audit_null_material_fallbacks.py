"""Freeze retained faces assigned null material exports; never mutate assets."""
import argparse, hashlib, json
from pathlib import Path
import numpy as np


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main(root):
    revision = root / 'tactical-visibility-revision'
    out = revision / 'null-material-fallback-audit-v1'
    out.mkdir(exist_ok=True)
    worlds = json.loads((root / 'completeness/combined-manifest-release-inputs-v2.json').read_text())
    source_cache, native_cache, summary = {}, {}, []
    for world in worlds:
        name = world['map']
        folder = Path(world['combinedWorldFolder'])
        metadata_path = folder / 'geometry.json'
        metadata = json.loads(metadata_path.read_text())
        candidates, missing = [], []
        for index, material in enumerate(metadata['materials']):
            if material.get('category') != 'opaque' or material.get('blendMode') != 0:
                continue
            path = Path(material.get('source', ''))
            if not path.is_file():
                missing.append(index)
                continue
            key = str(path)
            if key not in source_cache:
                data = json.loads(path.read_text())
                source_cache[key] = (data, sha(path))
            data, digest = source_cache[key]
            if isinstance(data, dict) and data.get('Parameters', {}).get('IsNull') is True:
                assert not material.get('sourceSha256') or material['sourceSha256'] == digest
                candidates.append((index, material, path, digest))
        correspondence_path = revision / f'full-height-input-v1/{name}/source-correspondence.npz'
        correspondence = np.load(correspondence_path)['sourceFaces']
        raw = np.load(folder / 'geometry.npz')
        material_ids = raw['material_indices'][correspondence]
        points, faces = raw['points'], raw['faces']
        objects = sorted(metadata['objects'], key=lambda o: o['firstFace'])
        starts = np.array([o['firstFace'] for o in objects])
        floor = json.loads((folder / 'floor-mesh.json').read_text())['floorMesh']
        # Floor mesh stores XY quantized, but Z as unquantized centimeters.
        floor_vertices = np.asarray(floor['vertices']).reshape(-1, 3).astype(float)
        floor_vertices[:, :2] /= floor['coordinateScale']
        floor_vertices[:, 2] /= 100
        standing_range = [float(floor_vertices[:, 2].min() + 1.75), float(floor_vertices[:, 2].max() + 1.75)]
        rows = []
        for material_index, material, path, digest in candidates:
            retained = np.flatnonzero(material_ids == material_index)
            if not len(retained):
                continue
            source_faces = correspondence[retained]
            vertices = points[faces[source_faces].ravel()]
            bounds = [vertices.min(axis=0).tolist(), vertices.max(axis=0).tolist()]
            parts = str(path).replace('\\', '/').split('/Content/')[-1].split('/')
            native = {'status': 'unresolved', 'reason': 'No exact placed export found'}
            if len(parts) >= 7 and parts[0] == 'Maps' and parts[3] == 'PersistentLevel':
                code, level = parts[1:3]
                native_path = root / f'native-material-audit/resolved-component-export/properties/ShooterGame/Content/Maps/{code}/{level}.json'
                if native_path.exists():
                    if str(native_path) not in native_cache:
                        native_cache[str(native_path)] = (json.loads(native_path.read_text()), sha(native_path))
                    data, native_sha = native_cache[str(native_path)]
                    outer = level + ':' + '.'.join(parts[3:-1])
                    matches = [(i, row) for i, row in enumerate(data) if row.get('Type') == 'MaterialInstanceDynamic' and row.get('Name') == path.stem and row.get('Outer', {}).get('ObjectName', '').split("'", 1)[-1].rstrip("'") == outer]
                    if len(matches) == 1:
                        export_index, matched = matches[0]
                        native = {'status': 'exact-placed-MID-parent-resolved', 'path': str(native_path), 'sha256': native_sha, 'exportIndex': export_index, 'outer': matched.get('Outer'), 'properties': matched.get('Properties')}
            object_indices, counts = np.unique(np.searchsorted(starts, source_faces, side='right') - 1, return_counts=True)
            rows.append({'materialIndex': material_index, 'materialMetadata': material, 'nullExportPath': str(path), 'nullExportSha256': digest, 'retainedFaceCount': len(retained), 'fullPackFaceIds': retained.tolist(), 'originalSourceFaceIds': source_faces.tolist(), 'retainedBoundsMeters': bounds, 'overlapsGlobalStandingEyeHeightRange': bounds[1][2] >= standing_range[0] and bounds[0][2] <= standing_range[1], 'objects': [{'path': objects[i]['path'], 'retainedFaceCount': int(count), 'sourceFirstFace': objects[i]['firstFace'], 'sourceFaceCount': objects[i]['faceCount']} for i, count in zip(object_indices, counts)], 'native': native})
        report = {'schemaVersion': 1, 'map': name, 'productionMutation': False, 'scope': 'Opaque blend-0 materials with explicit IsNull=true exported placeholder and retained full-height faces. Height priority is conservative global detailed-floor vertex range, not proof of a reachable sightline.', 'sourceGeometrySha256': metadata['geometrySha256'], 'metadataSha256': sha(metadata_path), 'fullHeightSourcePackSha256': sha(revision / f'full-height-input-v1/{name}/{name}.height.bin.gz'), 'correspondenceSha256': sha(correspondence_path), 'globalDetailedStandingEyeRangeMeters': standing_range, 'opaqueMaterialsWithoutReadableExport': missing, 'allNullOpaqueMaterialCount': len(candidates), 'rows': rows}
        (out / f'{name}.json').write_text(json.dumps(report, indent=2))
        item = {'map': name, 'nullOpaqueMaterials': len(candidates), 'retainedNullOpaqueMaterials': len(rows), 'retainedFaces': sum(r['retainedFaceCount'] for r in rows), 'heightPriorityFaces': sum(r['retainedFaceCount'] for r in rows if r['overlapsGlobalStandingEyeHeightRange']), 'resolvedMIDParents': sum(r['native']['status'] == 'exact-placed-MID-parent-resolved' for r in rows), 'opaqueMissingExport': len(missing)}
        summary.append(item)
        print(json.dumps(item), flush=True)
    (out / 'summary.json').write_text(json.dumps(summary, indent=2))


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('root', type=Path)
    main(parser.parse_args().root)

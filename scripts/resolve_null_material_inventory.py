"""Attach exact raw native definitions to the frozen null-export inventory."""
import hashlib
import json
from pathlib import Path


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    revision = Path('E:/IcarusWorldAudit/2026-09-06/tactical-visibility-revision')
    out = revision / 'null-material-fallback-audit-v1'
    packages = json.loads((out / 'base-material-packages.json').read_text())
    exports = revision / 'null-native-all-base-export-v1/properties/ShooterGame/Content'
    definitions = []
    for package in packages:
        path = exports / (package.removeprefix('/Game/') + '.json')
        values = json.loads(path.read_text())
        matches = [r for r in values if r.get('Name') == package.rsplit('/', 1)[-1]]
        assert len(matches) == 1
        raw = matches[0]
        properties = raw.get('Properties', {})
        record = {'package': package, 'path': str(path), 'sha256': sha(path), 'type': raw['Type'], 'properties': properties, 'compiledResourceCount': len(raw.get('LoadedMaterialResources', [])), 'explicitBlendMode': properties.get('BlendMode'), 'explicitTwoSided': properties.get('TwoSided', properties.get('BasePropertyOverrides', {}).get('TwoSided')), 'decision': 'No new visibility exclusion. Null processed exports are unresolved evidence, not proof of transparency. Explicit Unlit does not imply translucent.'}
        parent = properties.get('Parent', {}).get('ObjectPath')
        if parent:
            record['parentPackage'] = parent.rsplit('.', 1)[0]
            parent_paths = list((revision / 'null-native-archive-parent-export-v1').rglob(record['parentPackage'].rsplit('/', 1)[-1] + '.json'))
            if len(parent_paths) == 1:
                parent_path = parent_paths[0]
                parent_data = json.loads(parent_path.read_text())
                record['parentEvidence'] = {'path': str(parent_path), 'sha256': sha(parent_path), 'rows': [{k: v for k, v in row.items() if k not in ('LoadedMaterialResources', 'CachedExpressionData')} for row in parent_data]}
        definitions.append(record)
    report = {'schemaVersion': 1, 'productionMutation': False, 'retainedAssignments': 33, 'retainedFaces': 4543, 'placedMIDAssignments': 12, 'placedMIDFaces': 24, 'baseMaterialPackages': 12, 'baseMaterialAssignments': 21, 'baseMaterialFaces': 4519, 'confirmedClassificationDefect': 'Exact 12 Icebox Wind MIDs resolve to a translucent/unlit parent while processed IsNull placeholders were labeled opaque. Other null assignments need native material semantics; neither names nor missing BlendMode prove an exclusion.', 'receiverScopeWarning': 'Painted receiver overlap is a priority signal only. A retained blocker outside painted SVG may block rays crossing an unpainted gap and re-entering.', 'definitions': definitions}
    (out / 'native-resolution.json').write_text(json.dumps(report, indent=2))
    print('Resolved raw definitions:', len(definitions), 'parent definitions:', sum('parentEvidence' in row for row in definitions))


if __name__ == '__main__':
    main()

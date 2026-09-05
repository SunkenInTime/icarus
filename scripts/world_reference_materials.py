"""Resolve Blender material identifiers to audited source assets.

Names identify an asset; they never determine whether it is opaque. Ambiguous
or truncated identifiers remain unresolved instead of choosing a likely match.
"""
from pathlib import Path
import re


class MaterialCatalog:
    def __init__(self, audit):
        self.by_name = {}
        self.unresolved_meshes = set()
        for record in audit['materials'].values():
            source = record.get('source')
            if source:
                self.by_name.setdefault(Path(source).stem, {})[source] = record
        for issue in audit.get('issues', []):
            if issue['kind'] == 'unbound-subset':
                path = issue['path'].rsplit('/', 1)[0]
            elif issue['kind'] in ['unbound-faces', 'invalid-or-overlapping-material-subset']:
                path = issue['mesh']
            else:
                continue
            # One uncertain prototype makes the owning instancer uncertain.
            self.unresolved_meshes.add(path.split('/Prototypes/')[0])

    def unresolved_mesh(self, blender_path):
        path = '/' + '/'.join(re.sub(r'\.\d{3,}$', '', p) for p in blender_path.split('/') if p)
        return path if path in self.unresolved_meshes else None

    def resolve(self, name):
        if not name:
            return {'category': 'unresolved', 'reason': 'unbound-material'}
        candidates = self.by_name.get(name)
        if candidates is None:
            # Blender adds a numeric suffix when the importer creates another
            # material datablock for the same source identifier.
            base = re.sub(r'\.\d{3,}$', '', name)
            candidates = self.by_name.get(base)
        if not candidates:
            return {'category': 'unresolved', 'reason': 'unknown-material-identifier', 'blenderName': name}
        if len(candidates) != 1:
            return {'category': 'unresolved', 'reason': 'ambiguous-material-identifier', 'blenderName': name}
        record = next(iter(candidates.values()))
        return {'blenderName': name, 'source': record['source'],
                'sourceSha256': record['sourceSha256'],
                'category': record['category'], 'blendMode': record.get('blendMode'),
                'missingTextures': record.get('missingTextures', [])}

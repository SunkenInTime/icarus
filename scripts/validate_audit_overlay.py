"""Reject colored audit pixels where the independently masked coverage is zero."""
import argparse
import hashlib
import json
from pathlib import Path

import numpy as np
from PIL import Image


def inconsistent_pixels(overlay, visibility, artwork, tolerance=2):
    """Allow integer compositing roundoff, never visible color on zero coverage."""
    overlay, visibility, artwork = map(np.asarray, (overlay, visibility, artwork))
    if overlay.shape != visibility.shape or overlay.shape != artwork.shape:
        raise ValueError('Overlay, coverage and artwork must have equal RGBA shapes')
    alpha = artwork[:, :, 3:4].astype(float) / 255
    background = np.array([16, 16, 20])
    expected = artwork[:, :, :3] * alpha + background * (1 - alpha)
    return (visibility[:, :, 3] == 0) & (
        np.any(np.abs(overlay[:, :, :3].astype(float) - expected) > tolerance, axis=2)
        | (overlay[:, :, 3] != 255)
    )


def validate(folder):
    manifest_path = folder / 'manifest.json'
    manifest = json.loads(manifest_path.read_text())
    art_cache, failures = {}, []
    checked = 0
    for case in manifest['cases']:
        regions = case.get('rasterRegions', [])
        overlays = [r for r in regions if r['kind'] == 'overlay']
        if not overlays:
            overlays = [dict(scale=s, name='full', kind='overlay',
                             path=f"{case['prefix']}-{int(s)}x-overlay.png")
                        for s in manifest['scales']]
        for overlay in overlays:
            scale, name = overlay['scale'], overlay['name']
            key = case['side'], scale
            if key not in art_cache:
                art_cache[key] = Image.open(folder / f'{key[0]}-{int(scale)}x-art.png').convert('RGBA')
            art = art_cache[key]
            if 'pixelRect' in overlay:
                art = art.crop(overlay['pixelRect'])
                coverage_path = next(r['path'] for r in regions if r['kind'] == 'visibility'
                                     and r['scale'] == scale and r['name'] == name)
            else:
                coverage_path = f"{case['prefix']}-{int(scale)}x-visibility.png"
            color = Image.open(overlay['path']).convert('RGBA')
            coverage = Image.open(coverage_path).convert('RGBA')
            bad = inconsistent_pixels(color, coverage, art)
            checked += 1
            if np.any(bad):
                yy, xx = np.nonzero(bad)
                failures.append(dict(id=case['id'], side=case['side'], scale=scale,
                                     name=name, inconsistentPixels=int(bad.sum()),
                                     localPixelBounds=[int(xx.min()), int(yy.min()), int(xx.max()+1), int(yy.max()+1)],
                                     overlay=overlay['path'],
                                     overlaySha256=hashlib.sha256(Path(overlay['path']).read_bytes()).hexdigest(),
                                     coverage=coverage_path))
    report = dict(scope=__doc__, passed=not failures, checkedViews=checked,
                  toleranceRgb=2, failures=failures,
                  limitations='Checks only exact zero masked coverage; positive-coverage shading and game semantics remain separate checks.',
                  recovery='Preserve this failed output. An explicitly requested isolated recapture must use a fresh output directory and pass this validation. Never silently substitute its pixels.')
    (folder / 'overlay-consistency.json').write_text(json.dumps(report, indent=2))
    return report


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--folder', required=True, type=Path)
    args = parser.parse_args()
    result = validate(args.folder)
    print(f"Overlay consistency: {result['checkedViews']} views, {len(result['failures'])} failures")
    raise SystemExit(0 if result['passed'] else 1)

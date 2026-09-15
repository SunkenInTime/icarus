"""Material policy and alpha cutouts for offline standing visibility baking.

Only direct exported texture-alpha graphs are supported. Unknown bindings and
graphs remain solid and carry a reason. Resolved means understood by this
policy, not a certification of Riot's complete native material shader.
"""
from collections import Counter
from functools import lru_cache
import argparse
import hashlib
import json
import math
from pathlib import Path
import re


class AlphaSamplingError(ValueError):
    """The caller must retain the original solid segment and record this error."""


def _sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def _finite(value):
    return isinstance(value, (int, float)) and not isinstance(value, bool) and math.isfinite(value)


def _one(pattern, text, default=None):
    matches = re.findall(pattern, text)
    if len(matches) > 1:
        raise ValueError('ambiguous-usd-property')
    return matches[0] if matches else default


def _input(body, name, default=None):
    return _one(r'(?m)^\s*(?:uniform\s+)?\w+\s+' + re.escape(name) + r'\s*=\s*([^\r\n]+)', body, default)


def _number(text):
    value = float(text)
    if not math.isfinite(value):
        raise ValueError('nonfinite-usd-number')
    return value


def _vector(text, default):
    if text is None:
        return default
    if not text.startswith('(') or not text.endswith(')'):
        raise ValueError('unsupported-texture-transform')
    values = tuple(_number(v.strip()) for v in text[1:-1].split(','))
    if len(values) != 4:
        raise ValueError('unsupported-texture-transform')
    return values


def _connection(value):
    match = re.fullmatch(r'</([^<>]+)\.outputs:([A-Za-z0-9_]+)>', value or '')
    if not match:
        raise ValueError('unsupported-usd-connection')
    return match.group(1), match.group(2)


def _texture_metadata(texture, root):
    if root is None:
        return None, None
    pieces = texture.as_posix().split('/Exports/')
    if len(pieces) != 2:
        return None, None
    path = Path(root) / Path(pieces[1]).with_suffix('.json')
    if not path.is_file():
        return None, path
    objects = json.loads(path.read_text(encoding='utf-8'))
    candidates = [o for o in objects if o.get('Type') == 'Texture2D' and o.get('Name') == texture.stem]
    if len(candidates) != 1:
        raise ValueError('ambiguous-texture-properties')
    return candidates[0].get('Properties', {}), path


def build_policy(record, *, texture_properties_root=None):
    """Return an auditable solid, ignore or alpha-test policy for one record.

    ``record`` is a MaterialCatalog.resolve result or a materials.json record.
    ``texture_properties_root`` is the export's ``properties`` directory.
    Missing source hashes are allowed for hand-made fixtures; provided hashes
    must match. No Blender or USD Python module is required.
    """
    result = {'mode': 'solid', 'certain': False, 'gameplayCertified': False,
              'reason': 'unresolved-material', 'flags': []}
    for key in ['source', 'sourceSha256', 'blenderName', 'category', 'blendMode']:
        if key in record:
            result[key] = record[key]

    def unknown(reason):
        result.update(mode='solid', certain=False, reason=reason)
        return result

    if record.get('category') == 'unresolved' or not record.get('source'):
        return unknown(record.get('reason', 'unbound-material'))
    source = Path(record['source'])
    try:
        digest = _sha(source)
        if record.get('sourceSha256') and digest != record['sourceSha256']:
            return unknown('source-hash-mismatch')
        result['sourceSha256'] = digest
        data = json.loads(source.read_text(encoding='utf-8'))
        params = data.get('Parameters', {})
        blend = params.get('BlendMode')
        if not isinstance(blend, int) or isinstance(blend, bool):
            return unknown('missing-source-blend-mode')
        if record.get('blendMode') is not None and record['blendMode'] != blend:
            return unknown('source-blend-mode-disagrees-with-audit')
        result['blendMode'] = blend
        if blend == 0:
            result.update(certain=True, reason='source-opaque-blend')
            return result
        if blend in [2, 3, 4, 5]:
            result.update(mode='ignore', certain=True, reason={2: 'source-translucent-blend',
                          3: 'source-additive-blend', 4: 'source-modulate-blend',
                          5: 'source-alpha-composite-blend'}[blend])
            return result
        if blend != 1:
            return unknown('unsupported-source-blend-mode')

        usd = source.with_suffix('.usda')
        text = usd.read_text(encoding='utf-8')
        result.update(usdSource=str(usd), usdSha256=_sha(usd))
        material = _one(r'def Material "([^"\r\n]+)"', text)
        nodes = re.findall(r'def Shader "([^"\r\n]+)"\s*\{([^{}]*)\}', text)
        if not material or len(nodes) != len({n for n, _ in nodes}):
            return unknown('unsupported-material-usd-structure')
        shaders = dict(nodes)
        target, output = _connection(_input(text, 'outputs:surface.connect'))
        if not target.startswith(material + '/') or target.count('/') != 1 or output != 'surface':
            return unknown('unsupported-material-surface-connection')
        pbr = shaders.get(target.split('/')[1], '')
        if _input(pbr, 'info:id') != '"UsdPreviewSurface"':
            return unknown('unsupported-surface-shader')
        opacity = _input(pbr, 'inputs:opacity.connect')
        if opacity is None:
            return unknown('masked-material-without-connected-opacity')
        target, channel = _connection(opacity)
        if target.count('/') != 1 or not target.startswith(material + '/') or channel != 'a':
            return unknown('unsupported-opacity-channel-or-path')
        alpha = shaders.get(target.split('/')[1], '')
        if _input(alpha, 'info:id') != '"UsdUVTexture"':
            return unknown('unsupported-opacity-shader')
        texture_value = _input(alpha, 'inputs:file')
        if not texture_value or not re.fullmatch(r'@[^@\r\n]+@', texture_value) or '<UDIM>' in texture_value:
            return unknown('unsupported-alpha-texture-path')
        texture = (usd.parent / texture_value[1:-1]).resolve()
        if not texture.is_file():
            return unknown('missing-alpha-texture')
        target, output = _connection(_input(alpha, 'inputs:st.connect'))
        if target.count('/') != 1 or not target.startswith(material + '/') or output != 'result':
            return unknown('unsupported-alpha-uv-connection')
        primvar = shaders.get(target.split('/')[1], '')
        if _input(primvar, 'info:id') != '"UsdPrimvarReader_float2"' or _input(primvar, 'inputs:varname') != '"st"':
            return unknown('unsupported-alpha-uv-primvar')

        usd_threshold = _input(pbr, 'inputs:opacityThreshold')
        threshold = _number(usd_threshold) if usd_threshold is not None else None
        threshold_source = 'usd-connected-opacityThreshold'
        properties = params.get('Properties', {})
        override = properties.get('BasePropertyOverrides', {})
        if override.get('bOverride_OpacityMaskClipValue') is True:
            threshold = override.get('OpacityMaskClipValue')
            threshold_source = 'source-BasePropertyOverrides.OpacityMaskClipValue'
        elif 'OpacityMaskClipValue' in properties:
            threshold = properties['OpacityMaskClipValue']
            threshold_source = 'source-Properties.OpacityMaskClipValue'
        if not _finite(threshold) or not 0 < threshold <= 1:
            return unknown('missing-or-invalid-alpha-threshold')
        result['usdThreshold'] = _number(usd_threshold) if usd_threshold is not None else None
        if result['usdThreshold'] is not None and abs(threshold - result['usdThreshold']) > 1e-7:
            result['flags'].append('source-threshold-corrects-exported-preview-threshold')
        scale = _vector(_input(alpha, 'inputs:scale'), (1, 1, 1, 1))[3]
        bias = _vector(_input(alpha, 'inputs:bias'), (0, 0, 0, 0))[3]
        texture_props, metadata_path = _texture_metadata(texture, texture_properties_root)
        wraps = {}
        wrap_sources = {}
        address_values = {'TextureAddress::TA_Wrap': 'repeat', 'TextureAddress::TA_Clamp': 'clamp',
                          'TextureAddress::TA_Mirror': 'mirror', 0: 'repeat', 1: 'clamp', 2: 'mirror'}
        for axis, address in [('S', 'AddressX'), ('T', 'AddressY')]:
            authored = _input(alpha, 'inputs:wrap' + axis)
            authored = authored.strip('"') if authored else None
            if texture_props is not None:
                # CUE4Parse's UTexture2D calls GetOrDefault<TextureAddress>;
                # TA_Wrap is enum zero. Explicit cooked overrides beat that.
                value = texture_props.get(address, 0)
                if value not in address_values:
                    return unknown('unsupported-texture-address-mode')
                wraps[axis] = address_values[value]
                wrap_sources[axis] = ('source-texture.' + address if address in texture_props
                                     else 'source-texture-absent-address-CUE4Parse-TA_Wrap-default')
                if authored and authored != 'useMetadata' and authored != wraps[axis]:
                    result['flags'].append('source-texture-address-corrects-usd-wrap' + axis)
            elif authored in ['black', 'clamp', 'repeat', 'mirror']:
                wraps[axis] = authored
                wrap_sources[axis] = 'usd-authored-wrap' + axis
            else:
                wraps[axis] = 'repeat'
                wrap_sources[axis] = 'assumed-unreal-TA_Wrap-default-missing-texture-properties'
                result['flags'].append('unverified-game-texture-wrap' + axis)
        if texture_props is not None:
            result.update(textureProperties=str(metadata_path), texturePropertiesSha256=_sha(metadata_path))
        from PIL import Image
        with Image.open(texture) as img:
            size = list(img.size)
            alpha_range = img.convert('RGBA').getchannel('A').getextrema()
        result.update(mode='alpha-test', certain=texture_props is not None or all(v.startswith('usd-authored') for v in wrap_sources.values()),
                      reason='direct-source-texture-alpha-mask', alphaTexture=str(texture),
                      alphaTextureSha256=_sha(texture), threshold=float(threshold),
                      thresholdSource=threshold_source, uvPrimvar='st', wrapS=wraps['S'], wrapT=wraps['T'],
                      wrapSources=wrap_sources, alphaScale=scale, alphaBias=bias,
                      textureSize=size, textureAlphaRange=list(alpha_range),
                      shaderLimit='Exported preview graph does not establish native sampler overrides, shader UV changes, vertex alpha or mip selection.')
        return result
    except (OSError, ValueError, KeyError, TypeError) as error:
        return unknown('material-policy-error:' + str(error))


@lru_cache(maxsize=16)
def _alpha_image(path, expected_hash):
    import numpy as np
    from PIL import Image
    if expected_hash and _sha(path) != expected_hash:
        raise AlphaSamplingError('alpha-texture-hash-mismatch')
    with Image.open(path) as img:
        # USD st=(0,0) addresses the lower-left of the image.
        return np.asarray(img.convert('RGBA'), dtype=np.float32)[::-1, :, 3].copy() / 255.0


def _pixel(index, size, wrap):
    if wrap == 'repeat':
        return index % size
    if wrap == 'clamp':
        return min(size - 1, max(0, index))
    if wrap == 'mirror':
        pos = index % (size * 2)
        return pos if pos < size else 2 * size - 1 - pos
    if wrap == 'black':
        return index if 0 <= index < size else None
    raise AlphaSamplingError('unsupported-wrap-mode')


def _axis_pixel_ranges(origin, delta, size, wrap):
    """All texels that can influence an interval, including bilinear neighbors."""
    lo, hi = sorted((origin * size - .5, (origin + delta) * size - .5))
    lo, hi = math.floor(lo), math.floor(hi) + 1
    if wrap == 'repeat':
        if hi - lo + 1 >= size:
            return [(0, size)], False
        start, end = lo % size, hi % size
        return ([(start, end + 1)] if start <= end else [(start, size), (0, end + 1)]), False
    if wrap == 'mirror':
        # A mirrored consecutive integer interval has a consecutive image.
        # Include every texel if it spans a full period, otherwise inspect its
        # endpoints and any turn at a multiple of the image dimension.
        if hi - lo + 1 >= 2 * size:
            return [(0, size)], False
        points = [_pixel(lo, size, wrap), _pixel(hi, size, wrap)]
        for turn in range(lo // size + 1, hi // size + 1):
            points.extend((_pixel(turn * size - 1, size, wrap), _pixel(turn * size, size, wrap)))
        return [(min(points), max(points) + 1)], False
    if wrap == 'clamp':
        return [(max(0, min(size - 1, lo)), max(0, min(size - 1, hi)) + 1)], False
    if wrap == 'black':
        # A UV outside the tile samples black directly. Inside, border texels
        # can also interpolate against black neighbors.
        outside = lo < 0 or hi >= size
        start, end = max(0, lo), min(size, hi + 1)
        return ([(start, end)] if start < end else []), outside
    raise AlphaSamplingError('unsupported-wrap-mode')


def _segment_alpha_bounds(alpha, sx, sy, dx, dy, wrap_s, wrap_t):
    """Conservative exact bounds over the whole bilinear footprint rectangle."""
    h, w = alpha.shape
    xs, black_x = _axis_pixel_ranges(sx, dx, w, wrap_s)
    ys, black_y = _axis_pixel_ranges(sy, dy, h, wrap_t)
    lo, hi = (0.0, 0.0) if black_x or black_y else (math.inf, -math.inf)
    for x0, x1 in xs:
        for y0, y1 in ys:
            pixels = alpha[y0:y1, x0:x1]
            lo, hi = min(lo, float(pixels.min())), max(hi, float(pixels.max()))
    return lo, hi


def _cell_alpha_bounds(alpha, breaks, sx, sy, dx, dy, wrap_s, wrap_t):
    """Bound every crossed cell using its four bilinear contributors."""
    import numpy as np
    h, w = alpha.shape
    t = np.asarray(breaks)
    middle = t[:-1] + (t[1:] - t[:-1]) * .5
    u, v = sx + dx * middle, sy + dy * middle

    def addresses(values, size, wrap):
        pixels = values * size - .5
        if np.max(np.abs(pixels)) < 9e18:
            base = np.floor(pixels).astype(np.int64)
        else:
            # Preserve Python's arbitrary-size integer addressing for unusual
            # finite UVs outside the safe range of an int64 conversion.
            base = np.array([math.floor(float(p)) for p in pixels], dtype=object)
        indices = np.array([base, base + 1])
        if wrap == 'repeat':
            mapped = indices % size
        elif wrap == 'mirror':
            pos = indices % (2 * size)
            mapped = np.minimum(pos, 2 * size - 1 - pos)
        else:
            mapped = np.clip(indices, 0, size - 1)
        invalid = ((indices < 0) | (indices >= size)) if wrap == 'black' else None
        return mapped.astype(np.int64), invalid

    xs, black_x = addresses(u, w, wrap_s)
    ys, black_y = addresses(v, h, wrap_t)
    values = []
    for x, y in [(0, 0), (0, 1), (1, 0), (1, 1)]:
        value = alpha[ys[y], xs[x]]
        if black_x is not None:
            value = np.where(black_x[x], 0, value)
        if black_y is not None:
            value = np.where(black_y[y], 0, value)
        values.append(value)
    low = np.minimum.reduce(values).astype(np.float64)
    high = np.maximum.reduce(values).astype(np.float64)
    outside = np.zeros(len(middle), dtype=bool)
    if wrap_s == 'black':
        outside |= (u < 0) | (u > 1)
    if wrap_t == 'black':
        outside |= (v < 0) | (v > 1)
    low[outside] = high[outside] = 0
    return low, high


def clip_alpha_segment(policy, uv_start, uv_end, *, max_cells=100000):
    """Return solid t intervals along an alpha-tested section segment.

    UV varies linearly from uv_start to uv_end. Every texel boundary is split,
    then the quadratic bilinear-alpha function is solved for exact threshold
    crossings within each cell. The calculation uses the exported full-size
    alpha texture, not distance-dependent game mipmaps. On an exception callers
    must keep the original solid segment and record the failure.
    """
    if policy['mode'] == 'ignore':
        return []
    if policy['mode'] != 'alpha-test':
        return [(0.0, 1.0)]
    try:
        valid_uv = len(uv_start) == 2 and len(uv_end) == 2 and all(_finite(float(v)) for v in [*uv_start, *uv_end])
    except (ValueError, TypeError):
        valid_uv = False
    if not valid_uv:
        raise AlphaSamplingError('invalid-segment-uv')
    try:
        alpha = _alpha_image(policy['alphaTexture'], policy.get('alphaTextureSha256'))
    except (OSError, ValueError) as error:
        raise AlphaSamplingError(str(error)) from error
    h, w = alpha.shape
    sx, sy = map(float, uv_start)
    dx, dy = float(uv_end[0]) - sx, float(uv_end[1]) - sy
    wrap_s, wrap_t = policy['wrapS'], policy['wrapT']
    threshold = policy['threshold']
    scale, bias = policy.get('alphaScale', 1.0), policy.get('alphaBias', 0.0)
    extrema = policy.get('textureAlphaRange')
    if extrema:
        lo, hi = sorted(value / 255 * scale + bias for value in extrema)
        if 'black' in [wrap_s, wrap_t]:
            lo, hi = min(lo, bias), max(hi, bias)
        if lo >= threshold:
            return [(0.0, 1.0)]
        if hi < threshold:
            return []

    def sample(t):
        u, v = sx + dx * t, sy + dy * t
        if (wrap_s == 'black' and not 0 <= u <= 1) or (wrap_t == 'black' and not 0 <= v <= 1):
            return bias
        x, y = u * w - .5, v * h - .5
        ix, iy = math.floor(x), math.floor(y)
        fx, fy = x - ix, y - iy
        value = 0.0
        for xx, wx in [(ix, 1 - fx), (ix + 1, fx)]:
            px = _pixel(xx, w, wrap_s)
            if px is None:
                continue
            for yy, wy in [(iy, 1 - fy), (iy + 1, fy)]:
                py = _pixel(yy, h, wrap_t)
                if py is not None:
                    value += float(alpha[py, px]) * wx * wy
        return value * scale + bias

    breaks = {0.0, 1.0}
    for origin, delta, size, wrap in [(sx, dx, w, wrap_s), (sy, dy, h, wrap_t)]:
        if abs(delta) < 1e-15:
            continue
        a, b = sorted((origin * size - .5, (origin + delta) * size - .5))
        lo, hi = math.ceil(a), math.floor(b)
        if hi - lo > max_cells:
            raise AlphaSamplingError('alpha-segment-cell-budget-exceeded')
        for boundary in range(lo, hi + 1):
            t = ((boundary + .5) / size - origin) / delta
            if 0 < t < 1:
                breaks.add(t)
        if wrap == 'black':
            for boundary in [0, 1]:
                t = (boundary - origin) / delta
                if 0 < t < 1:
                    breaks.add(t)
    if len(breaks) > max_cells:
        raise AlphaSamplingError('alpha-segment-cell-budget-exceeded')
    # Bilinear interpolation is a convex combination of the four neighboring
    # texels. Uniform bounds over the complete footprint prove an entire
    # segment solid or empty, without sampling or solving any individual cell.
    lo, hi = sorted(value * scale + bias for value in
                    _segment_alpha_bounds(alpha, sx, sy, dx, dy, wrap_s, wrap_t))
    if lo >= threshold:
        return [(0.0, 1.0)]
    if hi + 1e-12 < threshold:
        return []
    breaks = sorted(breaks)
    import numpy as np
    low, high = _cell_alpha_bounds(alpha, breaks, sx, sy, dx, dy, wrap_s, wrap_t)
    low, high = (low * scale + bias, high * scale + bias) if scale >= 0 else (high * scale + bias, low * scale + bias)
    solid, empty = low >= threshold, high + 1e-12 < threshold
    # Adjacent cells proved solid already form complete intervals. Only cells
    # whose contributors straddle the threshold need the existing solver.
    transitions = np.diff(np.concatenate(([False], solid, [False])).astype(np.int8))
    intervals = [(breaks[start], breaks[end]) for start, end in
                 zip(np.flatnonzero(transitions == 1), np.flatnonzero(transitions == -1))]
    for cell in np.flatnonzero(~solid & ~empty):
        left, right = breaks[cell], breaks[cell + 1]
        span = right - left
        q1, q2, q3 = (sample(left + span * t) - threshold for t in [.25, .5, .75])
        a = 8 * (q1 - 2 * q2 + q3)
        b = 2 * (q3 - q1) - a
        c = q2 - .25 * a - .5 * b
        roots = []
        if abs(a) < 1e-12:
            if abs(b) > 1e-12:
                roots = [-c / b]
        else:
            discriminant = b * b - 4 * a * c
            if discriminant >= 0:
                r = math.sqrt(discriminant)
                roots = [(-b - r) / (2 * a), (-b + r) / (2 * a)]
        cuts = [0.0] + sorted(set(t for t in roots if 0 < t < 1)) + [1.0]
        for lo, hi in zip(cuts, cuts[1:]):
            if sample(left + span * (lo + hi) / 2) + 1e-12 < threshold:
                continue
            start, end = left + span * lo, left + span * hi
            intervals.append((start, end))
    merged = []
    for start, end in sorted(intervals):
        if merged and abs(merged[-1][1] - start) <= 1e-10:
            merged[-1] = (merged[-1][0], end)
        else:
            merged.append((start, end))
    return merged


def audit_material_policies(audit, *, texture_properties_root=None):
    policies = {source: build_policy(record, texture_properties_root=texture_properties_root)
                for source, record in {r['source']: r for r in audit['materials'].values() if r.get('source')}.items()}
    return {'schemaVersion': 1, 'status': 'offline-visibility-material-policy', 'gameplayCertified': False,
            'summary': {'uniqueSourceMaterials': len(policies),
                        'byMode': dict(Counter(p['mode'] for p in policies.values())),
                        'uncertainByReason': dict(Counter(p['reason'] for p in policies.values() if not p['certain'])),
                        'flags': dict(Counter(f for p in policies.values() for f in p['flags']))},
            'unresolvedBindingIssues': audit.get('issues', []), 'policies': policies}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('material_audit')
    parser.add_argument('output')
    parser.add_argument('--texture-properties-root')
    args = parser.parse_args()
    audit = json.loads(Path(args.material_audit).read_text(encoding='utf-8'))
    report = audit_material_policies(audit, texture_properties_root=args.texture_properties_root)
    report.update(materialAudit=args.material_audit, materialAuditSha256=_sha(args.material_audit))
    Path(args.output).write_text(json.dumps(report, indent=2), encoding='utf-8')
    print(json.dumps(report['summary'], indent=2))


if __name__ == '__main__':
    main()

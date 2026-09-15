"""Check the original Figma export and Discord screenshot against the calibration.

python scripts/audit_sunset_references.py --figma-svg <before.svg> --screenshot <image.png>
Dependencies: numpy, scipy, Pillow, svgpathtools, matplotlib.
Source files remain local; only the landmark fixture belongs in version control.
"""

import argparse
import hashlib
import json
from pathlib import Path

import numpy as np
from PIL import Image
from scipy.optimize import least_squares

from audit_sunset_scale import ROOT, FIXTURE, fit_uniform, load_artwork


def check_hash(path, expected):
    if hashlib.sha256(path.read_bytes()).hexdigest() != expected:
        raise ValueError(f"Reference changed: {path}. Re-identify the landmarks.")


def figma_check(fixture, path):
    baseline = fixture["figmaBaseline"]
    check_hash(path, baseline["exportSha256"])
    _, artwork = load_artwork(path)
    xy = []
    for item in baseline["landmarks"]:
        point = artwork[item["segment"]].start
        actual = [point.real, point.imag]
        if not np.allclose(actual, item["svg"], atol=1e-6):
            raise ValueError(f"Figma landmark changed: {item['name']}")
        xy.append(actual)
    xy = np.array(xy)
    uv = np.array([p["uv"] for p in fixture["landmarks"]])
    scale, translation = fit_uniform(uv[:6], xy[:6])
    residual = np.linalg.norm(uv[6:] * scale + translation - xy[6:], axis=1)
    result = {
        "svgUnitsPerUv": scale, "translation": translation.tolist(),
        "checkRmsSvg": float(np.sqrt(np.mean(residual ** 2))),
        "checkMaxSvg": float(residual.max()),
    }
    if result["checkRmsSvg"] > .75 or result["checkMaxSvg"] > 1.25:
        raise ValueError("Figma drawing fails the independent geometry checks.")
    return result


def screenshot_check(fixture, path, output):
    reference = fixture["discordReference"]
    check_hash(path, reference["sha256"])
    image = Image.open(path).convert("RGB")
    if list(image.size) != reference["imageSize"]:
        raise ValueError("Screenshot dimensions changed.")
    svg = np.array([p["svg"] for p in fixture["landmarks"][:6]])
    pixels = np.array(reference["landmarkPixels"])
    matrix, target = [], []
    for (x, y), (u, v) in zip(svg, pixels):
        matrix.extend([[x, -y, 1, 0], [y, x, 0, 1]])
        target.extend([u, v])
    transform = np.linalg.lstsq(matrix, target, rcond=None)[0]
    a, b, tx, ty = transform
    pixel_scale = np.hypot(a, b)
    predicted = (np.array(matrix) @ transform).reshape(-1, 2)
    landmark_error = np.linalg.norm(predicted - pixels, axis=1)
    rgb = np.array(image).astype(float)
    y, x = np.indices(rgb.shape[:2])
    cx, cy, radius = reference["circleInitial"]
    distance = np.hypot(x - cx, y - cy)
    mask = ((distance > radius - 4) & (distance < radius + 4)
            & (rgb.min(2) > 195) & (rgb.max(2) - rgb.min(2) < 25))
    xx, yy = x[mask], y[mask]
    circle = least_squares(
        lambda p: np.hypot(xx - p[0], yy - p[1]) - p[2],
        [cx, cy, radius], loss="soft_l1", f_scale=.5,
    ).x
    residual = np.abs(np.hypot(xx - circle[0], yy - circle[1]) - circle[2])
    inliers = residual < 1
    uv = np.array([p["uv"] for p in fixture["landmarks"][:6]])
    uv_scale, _ = fit_uniform(uv, svg)
    svg_per_meter = uv_scale * abs(fixture["uiData"]["xMultiplier"]) * 100
    effective_range = circle[2] / (pixel_scale * svg_per_meter)
    if landmark_error.max() > 2 or inliers.sum() < 250:
        raise ValueError("Screenshot registration or circle evidence is insufficient.")
    if abs(effective_range / fixture["currentRadiusMeters"] - 1) > .02:
        raise ValueError("Screenshot disagrees with the expected range by over 2%.")

    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    from matplotlib.patches import Circle
    fig, ax = plt.subplots(figsize=(12, 9), layout="constrained")
    ax.imshow(image)
    ax.scatter(*pixels.T, s=45, facecolors="none", edgecolors="#00ffff", label="Map landmarks")
    for i, (x, y) in enumerate(pixels):
        ax.annotate(str(i + 1), (x, y), (6, -7), textcoords="offset points", color="#00ffff")
    ax.scatter(xx[inliers], yy[inliers], s=2, color="#72ffb3", label="Detected range edge")
    ax.add_patch(Circle(circle[:2], circle[2], fill=False, ec="#72ffb3", lw=1))
    current_radius = 30 * 5.78 * .9502102049421427 * 473 / 831 * pixel_scale
    ax.add_patch(Circle(circle[:2], current_radius, fill=False, ec="#ff3f79", lw=2,
                        ls="--", label="Current Icarus radius at the same center"))
    ax.set_xlim(610, 1330)
    ax.set_ylim(910, 175)
    ax.set_title(f"Original Discord scene: registered landmarks and range edge\n"
                 f"Visible circle ≈ {effective_range:.1f} m; current Icarus ≈ 26.9 m")
    ax.legend(loc="upper left", fontsize=9)
    ax.set_axis_off()
    fig.savefig(output / "discord-scene-check.png", dpi=160)
    plt.close(fig)
    return {
        "similarityTransform": transform.tolist(), "pixelsPerSvgUnit": float(pixel_scale),
        "landmarkRmsPixels": float(np.sqrt(np.mean(landmark_error ** 2))),
        "landmarkMaxPixels": float(landmark_error.max()),
        "circleCenterPixels": circle[:2].tolist(), "circleRadiusPixels": float(circle[2]),
        "circleEdgeInliers": int(inliers.sum()), "visibleRadiusMeters": float(effective_range),
        "limitation": "Visual corroboration with manual landmarks, not a live gameplay distance test.",
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--figma-svg", type=Path, required=True)
    parser.add_argument("--screenshot", type=Path, required=True)
    parser.add_argument("--output", type=Path, default=ROOT / "artifacts/sunset-audit")
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    fixture = json.loads(FIXTURE.read_text())
    result = {"figma": figma_check(fixture, args.figma_svg),
              "discord": screenshot_check(fixture, args.screenshot, args.output)}
    (args.output / "reference-measurements.json").write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps(result, indent=2))


if __name__ == "__main__":
    main()

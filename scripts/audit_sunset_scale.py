"""Measure Sunset against pinned Riot landmarks, independently of ability sizes.

python -m pip install numpy svgpathtools matplotlib
python scripts/audit_sunset_scale.py --output artifacts/sunset-audit
Add --fmodel-content <ShooterGame/Content> to verify the original extracted files.
Add --check to reject a runtime scale more than 0.5% from the measured value.
"""

import argparse
import hashlib
import json
from pathlib import Path
import re
import xml.etree.ElementTree as ET

import numpy as np
from svgpathtools import parse_path


ROOT = Path(__file__).resolve().parents[1]
FIXTURE = ROOT / "test/fixtures/map_calibration/sunset.json"


def load_artwork(path):
    root = ET.parse(path).getroot()
    base = max(
        (e for e in root.iter() if e.tag.endswith("path")
         and e.get("fill", "").upper() == "#271406"),
        key=lambda e: len(e.get("d", "")),
    )
    return root, parse_path(base.get("d"))


def fit_uniform(uv, xy):
    """Fit one scale and a translation; do not stretch or rotate the artwork."""
    a, b = uv - uv.mean(axis=0), xy - xy.mean(axis=0)
    scale = float((a * b).sum() / (a * a).sum())
    return scale, xy.mean(axis=0) - scale * uv.mean(axis=0)


def verify_sources(fixture, content):
    for source in fixture["sourceFiles"]:
        path = content / source["path"]
        actual = hashlib.sha256(path.read_bytes()).hexdigest()
        if actual != source["sha256"]:
            raise ValueError(f"Source changed: {path}. Recalibrate; do not reuse old landmarks.")
    table = json.loads((content / fixture["sourceFiles"][1]["path"]).read_text())
    vertices = []
    for row in table[0]["Rows"].values():
        if row["Type"] == "v":
            vertices.append([row["X"], row["Y"]])
        elif vertices:
            break
    for landmark in fixture["landmarks"]:
        if not np.allclose(vertices[landmark["riotVertex"]], landmark["uv"], atol=1e-9):
            raise ValueError(f"Riot landmark changed: {landmark['name']}")


def analyze(fixture, artwork, runtime_scale, base_meters, virtual_height):
    root, path = load_artwork(artwork)
    viewbox = [float(v) for v in root.get("viewBox").split()]
    subpaths = path.continuous_subpaths()
    landmarks = fixture["landmarks"]
    for item in landmarks:
        point = subpaths[item["svgSubpath"]][item["svgSegment"]].start
        if not np.allclose([point.real, point.imag], item["svg"], atol=1e-6):
            raise ValueError(f"SVG landmark changed: {item['name']}. Recheck its correspondence.")
    uv = np.array([p["uv"] for p in landmarks])
    xy = np.array([p["svg"] for p in landmarks])
    training = np.array([p["role"] == "fit" for p in landmarks])
    scale, translation = fit_uniform(uv[training], xy[training])
    errors = np.linalg.norm(uv * scale + translation - xy, axis=1)
    affine = np.linalg.lstsq(
        np.column_stack([uv[training], np.ones(training.sum())]), xy[training], rcond=None
    )[0]
    axis_scales = np.linalg.norm(affine[:2], axis=1)
    uv_per_meter = abs(fixture["uiData"]["xMultiplier"]) * fixture["centimetersPerMeter"]
    if abs(abs(fixture["uiData"]["yMultiplier"]) * fixture["centimetersPerMeter"] - uv_per_meter) > 1e-12:
        raise ValueError("Anisotropic Riot projection needs a separate calibration.")
    svg_per_meter = scale * uv_per_meter
    recommended = svg_per_meter * virtual_height / (viewbox[3] * base_meters)
    actual_svg_per_meter = base_meters * runtime_scale * viewbox[3] / virtual_height
    radius_meters = fixture["currentRadiusMeters"]
    # Holding out the reported area prevents tuning the global scale to this placement.
    checks = errors[~training]
    if checks.max() > 1.25 or np.sqrt(np.mean(checks ** 2)) > 0.75:
        raise ValueError("Artwork check failed: inspect local geometry before changing scale.")
    result = {
        "svgUnitsPerUv": scale,
        "svgTranslation": translation.tolist(),
        "svgUnitsPerMeter": svg_per_meter,
        "fitLandmarks": int(training.sum()),
        "heldOutLandmarks": int((~training).sum()),
        "heldOutRmsSvg": float(np.sqrt(np.mean(checks ** 2))),
        "heldOutMaxSvg": float(checks.max()),
        "affineAxisScales": axis_scales.tolist(),
        "affineAxisRatio": float(axis_scales[0] / axis_scales[1]),
        "recommendedMapScale": recommended,
        "runtimeMapScale": runtime_scale,
        "rangeErrorPercent": (actual_svg_per_meter / svg_per_meter - 1) * 100,
        "radiusSvgExpected": radius_meters * svg_per_meter,
        "radiusSvgRuntime": radius_meters * actual_svg_per_meter,
        "effectiveRadiusMeters": radius_meters * actual_svg_per_meter / svg_per_meter,
        "landmarks": [dict(p, errorSvg=float(error)) for p, error in zip(landmarks, errors)],
    }
    return result, path


def plot(result, path, output):
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    from matplotlib.patches import Circle

    fig, axes = plt.subplots(1, 2, figsize=(13, 7), layout="constrained")
    for ax in axes:
        for subpath in path.continuous_subpaths():
            points = [segment.point(t) for segment in subpath for t in np.linspace(0, 1, 12)]
            ax.plot([p.real for p in points], [p.imag for p in points], color="#75614c", lw=0.9)
        ax.set_aspect("equal")
        ax.set_xlabel("SVG x")
        ax.set_ylabel("SVG y")
    ax = axes[0]
    for i, item in enumerate(result["landmarks"]):
        x, y = item["svg"]
        projected = np.array(item["uv"]) * result["svgUnitsPerUv"] + result["svgTranslation"]
        color = "#946500" if item["role"] == "fit" else "#006fc4"
        ax.plot(x, y, "o", color=color, markersize=4)
        ax.plot(*projected, "+", color="#dc2b40", markersize=6)
        ax.annotate(str(i + 1), (x, y), xytext=(5, 4), textcoords="offset points", fontsize=8)
    ax.set_xlim(-20, 445)
    ax.set_ylim(480, -5)
    ax.set_title("Riot landmarks on the unchanged artwork\n6 calibration points; 10 independent checks")
    ax = axes[1]
    # Approximate placement from the supplied Discord image; never used to fit scale.
    center = (302, 340)
    ax.add_patch(Circle(center, result["radiusSvgExpected"], fill=False, ec="#087f5b", lw=2,
                       label="30 m from Riot geometry"))
    ax.add_patch(Circle(center, result["radiusSvgRuntime"], fill=False, ec="#cc334e", lw=2,
                       ls="--", label=f"Icarus at {result['runtimeMapScale']:.3f}: {result['effectiveRadiusMeters']:.2f} m"))
    ax.plot(*center, "+", color="black")
    for label, point in [("Mid", (210, 290)), ("A Lobby", (325, 303)), ("A Elbow", (408, 240))]:
        ax.annotate(label, point, fontsize=10, backgroundcolor="white")
    ax.set_xlim(160, 435)
    ax.set_ylim(455, 195)
    ax.legend(loc="lower left", fontsize=9)
    ax.set_title("Same center, measured range correction\nIllustrative placement; scale fitted elsewhere")
    fig.suptitle("Sunset / Veto Crosscut", fontsize=18)
    fig.savefig(output / "sunset-calibration.png", dpi=190)
    fig.savefig(output / "sunset-calibration.svg")
    plt.close(fig)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--fmodel-content", type=Path)
    parser.add_argument("--output", type=Path, default=ROOT / "artifacts/sunset-audit")
    parser.add_argument("--candidate-scale", type=float)
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    fixture = json.loads(FIXTURE.read_text())
    if args.fmodel_content:
        verify_sources(fixture, args.fmodel_content)
    maps = (ROOT / "lib/const/maps.dart").read_text()
    runtime_scale = float(re.search(r"MapValue.sunset:\s*([\d.]+)", maps).group(1))
    if args.candidate_scale is not None:
        runtime_scale = args.candidate_scale
    agents = (ROOT / "lib/const/agents.dart").read_text()
    meters = float(re.search(r"inGameMeters\s*=\s*([\d.]+)", agents).group(1))
    coordinates = (ROOT / "lib/const/coordinate_system.dart").read_text()
    virtual_height = float(re.search(r"_baseHeight\s*=\s*([\d.]+)", coordinates).group(1))
    result, path = analyze(fixture, ROOT / "assets/maps/sunset_map.svg", runtime_scale, meters, virtual_height)
    args.output.mkdir(parents=True, exist_ok=True)
    (args.output / "measurements.json").write_text(json.dumps(result, indent=2) + "\n")
    plot(result, path, args.output)
    print(json.dumps({k: v for k, v in result.items() if k != "landmarks"}, indent=2))
    if args.check and abs(result["rangeErrorPercent"]) > 0.5:
        raise SystemExit("FAIL: range calibration differs by more than 0.5%.")


if __name__ == "__main__":
    main()

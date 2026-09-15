"""Render the candidate Sunset range beside the original Discord screenshot.

Uses the audit's measured landmark transform and beacon center. The candidate
is a calculated preview on the unchanged repository SVG, not an app capture.
Run after audit_sunset_scale.py and audit_sunset_references.py.
"""

import hashlib
import json
from pathlib import Path
import subprocess
import xml.etree.ElementTree as ET

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.lines import Line2D
from matplotlib.patches import Circle
from matplotlib.transforms import Affine2D
import numpy as np
from PIL import Image

from audit_sunset_scale import ROOT, FIXTURE, analyze


def main():
    output = ROOT / "artifacts/sunset-audit"
    fixture = json.loads(FIXTURE.read_text())
    screenshot = output / "discord-reference.png"
    assert hashlib.sha256(screenshot.read_bytes()).hexdigest() == fixture["discordReference"]["sha256"]
    measured = json.loads((output / "reference-measurements.json").read_text())["discord"]
    artwork = ROOT / "assets/maps/sunset_map.svg"
    candidate, _ = analyze(fixture, artwork, 1.06, 5.78, 831)
    candidate_radius = candidate["radiusSvgRuntime"] * measured["pixelsPerSvgUnit"]
    observed_radius = measured["circleRadiusPixels"]
    center = measured["circleCenterPixels"]

    # Render the actual SVG; do not approximate its contours or resize its paths.
    raster = output / "sunset-map-preview.png"
    renderer = ROOT / "artifacts/svg-render/node_modules/@resvg/resvg-js"
    code = """
const fs = require('node:fs');
const {Resvg} = require(process.argv[1]);
const svg = fs.readFileSync(process.argv[2]);
const result = new Resvg(svg, {fitTo:{mode:'zoom',value:3},font:{loadSystemFonts:false}}).render();
fs.writeFileSync(process.argv[3], result.asPng());
"""
    subprocess.run(["node", "-e", code, str(renderer), str(artwork), str(raster)], check=True)
    width, height = map(float, [ET.parse(artwork).getroot().get(k) for k in ("width", "height")])
    a, b, tx, ty = measured["similarityTransform"]
    transform = Affine2D.from_values(a, b, -b, a, tx, ty)
    cyan, orange = "#25d8f1", "#ffb44a"
    crop = (855, 1300, 435, 884)
    plt.rcParams.update({"font.family": "DejaVu Sans", "font.size": 12})
    fig, axes = plt.subplots(1, 2, figsize=(14, 8.1), facecolor="#10171e")
    fig.subplots_adjust(left=.028, right=.972, bottom=.15, top=.83, wspace=.035)
    fig.text(.5, .955, "Sunset: corrected sizing vs. the screenshot", ha="center",
             color="white", fontsize=22, weight="bold")
    fig.text(.5, .910, "Same map scale, orientation and beacon center", ha="center",
             color="#b9c6d1", fontsize=13)
    for ax in axes:
        ax.set_facecolor("#141c24")
        ax.set_xlim(crop[0], crop[1])
        ax.set_ylim(crop[3], crop[2])
        ax.set_aspect("equal")
        ax.set_xticks([])
        ax.set_yticks([])
        for spine in ax.spines.values():
            spine.set_color("#45515c")

    axes[0].imshow(Image.open(screenshot))
    axes[0].add_patch(Circle(center, observed_radius, fill=False, ec=orange, lw=1.6))
    axes[0].set_title("In-game screenshot", color="white", pad=13, fontsize=15)

    axes[1].imshow(Image.open(raster), extent=(0, width, height, 0),
                   transform=transform + axes[1].transData, interpolation="bilinear")
    axes[1].add_patch(Circle(center, candidate_radius, facecolor=cyan, edgecolor="none", alpha=.16))
    axes[1].add_patch(Circle(center, candidate_radius, fill=False, ec=cyan, lw=2.1))
    axes[1].add_patch(Circle(center, observed_radius, fill=False, ec=orange, lw=1.5, ls=(0, (5, 4))))
    axes[1].plot(*center, "+", color="white", ms=12, mew=1.5)
    axes[1].annotate("Beacon", center, (10, 9), textcoords="offset points", color="white", fontsize=10)
    for label, x, y in [("Mid Tiles", 990, 574), ("A Main", 1128, 549),
                        ("A Lobby", 1126, 633), ("A Elbow", 1244, 475)]:
        axes[1].text(x, y, label, color="#eee7dc", fontsize=10, ha="center",
                     bbox={"facecolor":"#141c24", "edgecolor":"none", "alpha":.7, "pad":2})
    axes[1].set_title("Corrected Icarus preview · scale 1.06", color="white", pad=13, fontsize=15)
    handles = [Line2D([0], [0], color=cyan, lw=2.5, label="Corrected range"),
               Line2D([0], [0], color=orange, lw=2, ls="--", label="Measured screenshot edge")]
    legend = fig.legend(handles=handles, loc="lower center", bbox_to_anchor=(.5, .092),
                        ncol=2, frameon=False, fontsize=12)
    for text in legend.get_texts():
        text.set_color("#e4edf3")
    delta = candidate_radius - observed_radius
    difference = delta / observed_radius * 100
    fig.text(.5, .070, f"Radius at original screenshot resolution: {observed_radius:.2f} px in-game"
             f"  /  {candidate_radius:.2f} px corrected  ·  {difference:.2f}% difference",
             ha="center", color="#c6d4df", fontsize=11)
    fig.text(.5, .032, "Calculated preview from the audit, not a live application capture."
             " The screenshot measurement has pixel-level uncertainty.",
             ha="center", color="#93a6b6", fontsize=10)
    fig.savefig(output / "sunset-fixed-vs-screenshot.png", dpi=160, facecolor=fig.get_facecolor())
    fig.savefig(output / "sunset-fixed-vs-screenshot.pdf", facecolor=fig.get_facecolor())
    plt.close(fig)

    # A second view puts the candidate directly on the original frame.
    fig, ax = plt.subplots(figsize=(8, 8), layout="constrained")
    ax.imshow(Image.open(screenshot))
    ax.add_patch(Circle(center, candidate_radius, fill=False, ec=cyan, lw=2))
    ax.add_patch(Circle(center, observed_radius, fill=False, ec=orange, lw=1.5, ls=(0, (5, 4))))
    ax.plot(*center, "+", color="white", ms=12)
    ax.set_xlim(crop[:2]); ax.set_ylim(crop[3], crop[2]); ax.set_axis_off()
    ax.set_title("Corrected range on the original screenshot", fontsize=15, pad=15)
    ax.legend(handles=handles, loc="lower left", fontsize=10)
    fig.savefig(output / "sunset-fixed-overlay.png", dpi=160)
    plt.close(fig)
    result = {
        "candidateScale": 1.06, "sameCenterPixels": center,
        "screenshotRadiusPixels": observed_radius,
        "correctedRadiusPixels": candidate_radius,
        "radiusDifferencePixels": delta, "radiusDifferencePercent": difference,
        "screenshotDiameterPixels": observed_radius * 2,
        "correctedDiameterPixels": candidate_radius * 2,
        "sourceArtworkSha256": hashlib.sha256(artwork.read_bytes()).hexdigest(),
        "sourceScreenshotSha256": fixture["discordReference"]["sha256"],
        "note": "Measured preview; runtime correction remains unapplied.",
    }
    (output / "fixed-comparison.json").write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps(result, indent=2))


if __name__ == "__main__":
    main()

"""Plot boundary evidence exported by tool/audit_vision_boundaries_test.dart.

python scripts/plot_vision_audit.py build/vision-audit/split.json
"""

import argparse
import json
from pathlib import Path

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.collections import LineCollection


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("report", type=Path)
    args = parser.parse_args()
    report = json.loads(args.report.read_text(encoding="utf-8"))
    side = report["sides"][0]
    layers, groups = side["layers"], side["groups"]
    chosen = min(layers, key=lambda layer: abs(layer["elevation"] - 300))
    outer = next(g for g in groups if g["outer"])
    left, top, right, bottom = outer["bounds"]
    all_points = [p for layer in layers for segment in layer["sourceSegments"] for p in segment]
    if all_points:
        left = min(left, min(p[0] for p in all_points))
        right = max(right, max(p[0] for p in all_points))
        top = min(top, min(p[1] for p in all_points))
        bottom = max(bottom, max(p[1] for p in all_points))
    background = "#111820"
    plt.rcParams.update({"font.family": "DejaVu Sans", "text.color": "#edf1f5"})
    fig, axes = plt.subplots(2, 2, figsize=(14, 13), facecolor=background)
    for ax in axes.flat:
        ax.set_facecolor(background)
        ax.set_xlim(left - 25, right + 25)
        ax.set_ylim(bottom + 25, top - 25)
        ax.set_aspect("equal")
        ax.axis("off")

    def lines(ax, segments, color, width=1, alpha=1):
        ax.add_collection(LineCollection(segments, colors=color,
            linewidths=width, alpha=alpha))

    lines(axes[0, 0], chosen["runtimeSegments"], "#e4b873", 1.1)
    counts = [len(layer["runtimeSegments"]) for layer in layers]
    distinct = len({json.dumps(layer["runtimeSegments"]) for layer in layers})
    axes[0, 0].set_title(f"Current Icarus blockers\n{len(layers)} elevations, {distinct} distinct segment set{'s' if distinct != 1 else ''}", loc="left", pad=15)

    lines(axes[0, 1], chosen["runtimeSegments"], "#697582", 0.7, 0.7)
    lines(axes[0, 1], chosen["sourceSegments"], "#59c9e7", 1.2)
    axes[0, 1].set_title(f"Extracted contours at Z={chosen['elevation']:g}\nCyan source over gray runtime, current projection", loc="left", pad=15)

    lines(axes[1, 0], chosen["runtimeSegments"], "#697582", 0.7, 0.5)
    candidates = sorted([g for g in groups if not g["outer"] and g["flags"]],
        key=lambda g: g["perimeter"], reverse=True)
    for g in candidates:
        if "active-without-contour-match" in g["flags"]:
            color = "#f47b72"
        elif "active-beyond-matched-elevations" in g["flags"]:
            color = "#e8b84e"
        else:
            continue
        segments = [(a, b) for path in g["paths"] for a, b in zip(path, path[1:])]
        lines(axes[1, 0], segments, color, 1.6)
    axes[1, 0].set_title("Candidates for investigation\nRed: no contour match. Gold: extra active elevations.", loc="left", pad=15)

    low, high = layers[0], layers[-1]
    lines(axes[1, 1], low["sourceSegments"], "#59c9e7", 1.2, 0.8)
    lines(axes[1, 1], high["sourceSegments"], "#d98de3", 1.2, 0.8)
    axes[1, 1].set_title(f"The source changes with height\nCyan Z={low['elevation']:g}, purple Z={high['elevation']:g}", loc="left", pad=15)
    name = report["summary"]["map"].capitalize()
    fig.suptitle(f"{name} vision-boundary audit", x=0.07, ha="left", fontsize=22, y=0.98)
    fig.text(0.07, 0.018, "Diagnostic comparison, not verified gameplay truth. Projection and contour semantics can both differ.\n"
        "Runtime segments shown before observer-specific exclusions. No map assets were modified.", fontsize=10, color="#b7c4d1")
    fig.subplots_adjust(left=0.07, right=0.96, top=0.91, bottom=0.08, wspace=0.16, hspace=0.22)
    output = args.report.with_name(args.report.stem + "-comparison.png")
    fig.savefig(output, dpi=150, facecolor=background)
    plt.close(fig)
    print(json.dumps({"output": str(output), "runtimeSegmentCounts": counts,
        "distinctRuntimeLayers": distinct, "candidateCount": len(candidates)}))


if __name__ == "__main__":
    main()

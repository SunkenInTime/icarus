"""Separate the remaining screenshot mismatch from Icarus's SVG geometry.

The primary fit goes directly from pinned Riot UV points to screenshot pixels.
It does not load or measure an Icarus SVG.
"""
import hashlib
import json
from pathlib import Path

import numpy as np
from PIL import Image
from scipy.optimize import least_squares

from audit_sunset_scale import ROOT, FIXTURE


def fit_similarity(points, targets):
    matrix, values = [], []
    for (x, y), (u, v) in zip(points, targets):
        matrix.extend([[x, -y, 1, 0], [y, x, 0, 1]])
        values.extend([u, v])
    transform = np.linalg.lstsq(matrix, values, rcond=None)[0]
    residuals = (np.array(matrix) @ transform - values).reshape(-1, 2)
    return float(np.hypot(*transform[:2])), np.linalg.norm(residuals, axis=1)


def main():
    fixture = json.loads(FIXTURE.read_text())
    output = ROOT / "artifacts/sunset-audit"
    screenshot = output / "discord-reference.png"
    assert hashlib.sha256(screenshot.read_bytes()).hexdigest() == fixture["discordReference"]["sha256"]
    uv = np.array([p["uv"] for p in fixture["landmarks"] if p["role"] == "fit"])
    pixels = np.array(fixture["discordReference"]["landmarkPixels"])
    uv_per_meter = abs(fixture["uiData"]["xMultiplier"]) * fixture["centimetersPerMeter"]
    radius_meters = fixture["currentRadiusMeters"]
    scale, errors = fit_similarity(uv, pixels)
    direct_radius = scale * uv_per_meter * radius_meters
    leave_one_out = [
        fit_similarity(np.delete(uv, i, 0), np.delete(pixels, i, 0))[0]
        * uv_per_meter * radius_meters for i in range(len(uv))
    ]

    rgb = np.array(Image.open(screenshot).convert("RGB")).astype(float)
    y, x = np.indices(rgb.shape[:2])
    initial = fixture["discordReference"]["circleInitial"]
    distance = np.hypot(x - initial[0], y - initial[1])
    # A sensitivity check, not a statistical confidence interval. High brightness
    # cutoffs omit much of the translucent circle, so retain broad edge coverage.
    threshold_checks = []
    for brightness, chroma in [(170, 20), (180, 25), (195, 25), (210, 20)]:
        mask = ((distance > initial[2] - 4) & (distance < initial[2] + 4)
                & (rgb.min(2) > brightness) & (rgb.max(2) - rgb.min(2) < chroma))
        xx, yy = x[mask], y[mask]
        circle = least_squares(
            lambda p: np.hypot(xx-p[0], yy-p[1])-p[2],
            initial, loss="soft_l1", f_scale=.5,
        ).x
        threshold_checks.append({"brightness": brightness, "chroma": chroma,
                                 "edgeCandidates": int(mask.sum()),
                                 "radiusPixels": float(circle[2])})

    comparison = json.loads((output / "fixed-comparison.json").read_text())
    observed = comparison["screenshotRadiusPixels"]
    result = {
        "method": "Riot UV points directly to screenshot pixels; no SVG in this fit",
        "directPixelsPerUv": scale,
        "directLandmarkMaxErrorPixels": float(errors.max()),
        "directExpected30mRadiusPixels": direct_radius,
        "measuredScreenshotRadiusPixels": observed,
        "directDifferencePixels": direct_radius-observed,
        "leaveOneOutExpectedRadiiPixels": leave_one_out,
        "circleThresholdChecks": threshold_checks,
        "screenshotMatchingMapScale": comparison["candidateScale"] * observed / comparison["correctedRadiusPixels"],
        "interpretation": "The disagreement persists without the SVG. Matching this one indicator does not establish the correct physical scale.",
    }
    (output / "residual-measurements.json").write_text(json.dumps(result, indent=2)+"\n")
    print(json.dumps(result, indent=2))


if __name__ == "__main__":
    main()

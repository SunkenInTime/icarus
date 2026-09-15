"""Find source-measured openings that current wall assignments may obscure."""

import argparse
import gzip
import hashlib
import json
from collections import Counter, defaultdict
from pathlib import Path

import numpy as np
import shapely
from shapely.affinity import affine_transform

from compile_reviewed_svg_height_map import polygon
from audit_assumed_svg_height_sections import clipped_height_intervals, merge_intervals


ROOT = Path("E:/IcarusWorldAudit/2026-09-06")
PROFILE_ROOT = ROOT / "tactical-visibility-revision/all-map-finite-heights-v7"
MIN_GAP = 1.96
POINT_RADIUS = 0.08


def read(path):
    raw = path.read_bytes()
    return json.loads(gzip.decompress(raw) if path.suffix == ".gz" else raw)


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def wall_active(wall, elevation):
    if wall.get("unknownHeight"):
        return True
    floor = float(wall.get("floorElevationMeters", 0.0))
    return any((float(lo) == 0 or (floor + float(lo)) <= elevation) and elevation <= (float("inf") if hi is None else floor + float(hi))
               for lo, hi in wall.get("bands", []))


def source_gaps(station, source_bands=None):
    bands = sorted((float(lo), float(hi)) for lo, hi in (source_bands if source_bands is not None else station.get("sourceBands", [])) if hi is not None)
    return [(bands[i][1], bands[i + 1][0]) for i in range(len(bands) - 1) if bands[i + 1][0] > bands[i][1]]


def wall_index(model):
    shapes = [polygon(row) for row in model["walls"]]
    return shapes, shapely.STRtree(shapes)


def state_at(model, index, point, elevation):
    shapes, tree = index
    probe = shapely.Point(point).buffer(POINT_RADIUS)
    hits = [int(i) for i in tree.query(probe, predicate="intersects")]
    active = [model["walls"][i]["id"] for i in hits if wall_active(model["walls"][i], elevation)]
    return {"filled": bool(active), "activeWallIds": active[:8], "wallHits": len(hits)}


def standing_index(model):
    if "standingTriangles" not in model["ground"]:
        return None
    vertices = np.asarray(model["ground"]["vertices"], dtype=float).reshape(-1, 3)
    faces = np.asarray(model["ground"]["triangles"], dtype=int).reshape(-1, 3)
    ids = np.asarray(model["ground"]["standingTriangles"], dtype=int)
    triangles = vertices[faces[ids]]
    shapes = [shapely.Polygon(row[:, :2]) for row in triangles]
    return ids, triangles, shapes, shapely.STRtree(shapes)


def standing_eye_at(index, point, camera_height):
    ids, triangles, shapes, tree = index
    p = shapely.Point(point)
    for local in sorted(tree.query(p, predicate="intersects"), key=lambda value: int(ids[int(value)])):
        local = int(local)
        triangle = triangles[local]
        xy = triangle[:, :2]
        matrix = np.c_[xy, np.ones(3)]
        try:
            weights = np.linalg.solve(matrix.T, [point[0], point[1], 1.0])
        except np.linalg.LinAlgError:
            continue
        return {"eyeElevationMeters": float(weights @ triangle[:, 2] + camera_height),
                "standingTriangle": int(ids[local]), "svg": list(map(float, point))}
    return None


def adjacent_standing_eyes(model, standing, wall_index_value, point, tangent):
    if standing is None:
        return []
    receiver = shapely.union_all([polygon(row) for row in model["receiver"]])
    normal = np.array([-tangent[1], tangent[0]])
    camera = float(model.get("defaultCameraHeightMeters", 1.75))
    results = []
    for distance in [.6, 1.0, 1.5]:
        for sign in [-1, 1]:
            candidate = point + sign * distance * normal
            if not receiver.covers(shapely.Point(candidate)):
                continue
            retained = standing_eye_at(standing, candidate, camera)
            if retained is None:
                continue
            clearance = state_at(model, wall_index_value, candidate, retained["eyeElevationMeters"])
            if clearance["filled"]:
                continue
            retained.update(offsetSvg=distance, receiverSide=sign, wallClear=True)
            results.append(retained)
    return results


def current_source_bands(station, tangent, triangles, objects):
    components = station.get("sourceComponents") or []
    if not components or station.get("sourceObject") is None or not station.get("sourcePath"):
        return None, "missing-source-ownership"
    primary = int(station["sourceObject"])
    if primary >= len(objects) or objects[primary]["path"] != station["sourcePath"]:
        return None, "source-path-object-mismatch"
    intervals = []
    for component in components:
        oid = int(component["object"])
        if oid >= len(objects):
            return None, "source-component-object-out-of-range"
        first = int(objects[oid]["firstFace"])
        end = first + int(objects[oid]["faceCount"])
        faces = np.asarray(component.get("faces", []), dtype=int)
        if not len(faces) or np.any((faces < first) | (faces >= end)):
            return None, "source-face-ownership-mismatch"
        _, measured = clipped_height_intervals(triangles[faces], np.asarray(station["native"]), tangent, .15, .85, include_flat=True)
        intervals.extend(measured.tolist())
    return merge_intervals(intervals), None


def transform_point(point, transform):
    return np.asarray(point) @ transform[:, :2].T + transform[:, 2]


def group_rows(rows, keys):
    groups = defaultdict(list)
    for row in rows:
        groups[tuple(tuple(value) if isinstance(value := row.get(key), list) else value for key in keys)].append(row)
    result = []
    for key, members in groups.items():
        result.append({**dict(zip(keys, key)), "stationCount": len(members),
                       "filledAttack": sum(row["sides"]["attack"]["filled"] for row in members),
                       "filledDefense": sum(row["sides"]["defense"]["filled"] for row in members),
                       "filledBothSides": sum(row["sides"]["attack"]["filled"] and row["sides"]["defense"]["filled"] for row in members),
                       "standingEyeStations": sum(row.get("standingEyeInsideGap", False) for row in members),
                       "sampleStations": [{"index": row["stationIndex"], "svg": row["svg"], "gap": row.get("gap"), "eyes": row.get("nearbyEyes", [])} for row in members[:6]]})
    return sorted(result, key=lambda row: (-row["stationCount"], *(str(row.get(key)) for key in keys)))


def candidate_families(rows):
    families = defaultdict(list)
    for row in rows:
        if row["standingEyeInsideGap"] and row["sides"]["attack"]["filled"] and row["sides"]["defense"]["filled"]:
            families[(row["parent"], row["assembly"])].append(row)
    result = []
    for (parent, assembly), members in families.items():
        result.append({"parent": parent, "assembly": assembly,
                       "stationCount": len({row["stationIndex"] for row in members}),
                       "gapInstanceCount": len(members),
                       "sourceObjects": sorted({row["sourceObject"] for row in members if row["sourceObject"] is not None}),
                       "members": members})
    return sorted(result, key=lambda row: (-row["stationCount"], -row["gapInstanceCount"], row["parent"], row["assembly"]))


def analyze(map_name, profile_path, asset_paths, expected_asset_hashes=None):
    profile = read(profile_path)
    models = {side: read(path) for side, path in asset_paths.items()}
    indices = {side: wall_index(model) for side, model in models.items()}
    alignment_path = ROOT / f"tactical-alignment-sides-v1/{map_name}.json"
    alignment = read(alignment_path)
    attack = np.asarray(alignment["nativeToAttackSvg"], dtype=float)
    defense = np.asarray(alignment["nativeToDefenseSvg"], dtype=float)
    linear = defense[:, :2] @ np.linalg.inv(attack[:, :2])
    transform = np.c_[linear, defense[:, 2] - linear @ attack[:, 2]]
    geometry_path = ROOT / f"supplemented-v2/world/{map_name}/geometry.npz"
    metadata_path = geometry_path.with_suffix(".json")
    fingerprints = {"profile": sha(profile_path), "alignment": sha(alignment_path), "geometry": sha(geometry_path), "metadata": sha(metadata_path),
                    "assetAttack": sha(asset_paths["attack"]), "assetDefense": sha(asset_paths["defense"])}
    checks = {"alignment": profile.get("alignmentSha256") == fingerprints["alignment"],
              "geometry": profile.get("sourceGeometrySha256") == fingerprints["geometry"],
              "metadata": profile.get("sourceMetadataSha256") == fingerprints["metadata"]}
    if expected_asset_hashes:
        checks.update({f"asset-{side}": fingerprints[f"asset{side.title()}"] == expected_asset_hashes[side]
                       for side in ["attack", "defense"]})
    source_mismatch = not all(checks[key] for key in ["alignment", "geometry", "metadata"])
    current_source = None
    if source_mismatch and checks["alignment"]:
        geometry = np.load(geometry_path)
        current_source = (geometry["points"][geometry["faces"]], read(metadata_path)["objects"])
    status = "review-only" if all(checks.values()) else "review-only-current-source-remeasurement"

    gaps, overhead = [], []
    unresolved_source = []
    eye_states = {side: defaultdict(list) for side in ["attack", "defense"]}
    attack_standing = standing_index(models["attack"])
    for record in profile["records"]:
        stations = record["stations"]
        for station_index, station in enumerate(stations):
            attack_point = np.asarray(station.get("associationSvg", station["svg"]), dtype=float)
            defense_point = transform_point(attack_point, transform)
            floor = float(station.get("floorElevationMeters", 0.0))
            before = stations[max(0, station_index - 1)]
            after = stations[min(len(stations) - 1, station_index + 1)]
            svg_tangent = np.asarray(after.get("associationSvg", after["svg"]), dtype=float) - np.asarray(before.get("associationSvg", before["svg"]), dtype=float)
            native_tangent = np.asarray(after["native"], dtype=float) - np.asarray(before["native"], dtype=float)
            if np.linalg.norm(svg_tangent) < 1e-9 or np.linalg.norm(native_tangent) < 1e-9:
                unresolved_source.append({"parent": record["wallId"], "stationIndex": station_index,
                                          "sourceObject": station.get("sourceObject"), "sourcePath": station.get("sourcePath"),
                                          "reason": "degenerate-station-tangent"})
                continue
            svg_tangent /= np.linalg.norm(svg_tangent)
            native_tangent /= np.linalg.norm(native_tangent)
            retained_eyes = adjacent_standing_eyes(models["attack"], attack_standing, indices["attack"], attack_point, svg_tangent)
            eye = floor + float(models["attack"].get("defaultCameraHeightMeters", 1.75))
            states = {"attack": state_at(models["attack"], indices["attack"], attack_point, eye),
                      "defense": state_at(models["defense"], indices["defense"], defense_point, eye)}
            for side, point in [("attack", attack_point), ("defense", defense_point)]:
                eye_states[side][record["wallId"]].append({"stationIndex": station_index, "distance": station.get("distanceSvg", station_index), "filled": states[side]["filled"], "eye": eye, "svg": point.tolist()})
            assembly = station.get("sourcePath") or str(station.get("sourceObject"))
            source_bands = None
            if current_source is not None:
                source_bands, reason = current_source_bands(station, native_tangent, *current_source)
                if reason:
                    if source_gaps(station):
                        unresolved_source.append({"parent": record["wallId"], "stationIndex": station_index,
                                                  "sourceObject": station.get("sourceObject"), "sourcePath": station.get("sourcePath"),
                                                  "sourceFaces": station.get("sourceFaces", []), "reason": reason})
                    continue
            for lo, hi in source_gaps(station, source_bands):
                standing_positions = [row for row in retained_eyes if lo < row["eyeElevationMeters"] < hi]
                standing_eye = bool(standing_positions)
                if hi - lo < MIN_GAP and not standing_eye:
                    continue
                mid = (lo + hi) / 2
                sides = {"attack": state_at(models["attack"], indices["attack"], attack_point, mid),
                         "defense": state_at(models["defense"], indices["defense"], defense_point, mid)}
                if not sides["attack"]["filled"] and not sides["defense"]["filled"]:
                    continue
                gaps.append({"parent": record["wallId"], "assembly": assembly, "sourceObject": station.get("sourceObject"), "sourceRole": station.get("sourceRole"),
                             "gap": [lo, hi], "gapBucket": [round(lo, 1), round(hi, 1)], "stationIndex": station_index, "svg": attack_point.tolist(),
                             "retainedStandingPositions": standing_positions, "standingEyeInsideGap": standing_eye,
                             "sourceMeasurement": "current-exact-owned-faces" if current_source is not None else "frozen-fingerprint-matched-profile",
                             "navigationPassageAbsent": station.get("status") != "navigation-passage", "sides": sides})
            if station.get("sourceRole") == "overhead" and station.get("measuredBottomMeters") is not None:
                bottom = float(source_bands[0][0] if source_bands else station["measuredBottomMeters"])
                below = [row for row in retained_eyes if row["eyeElevationMeters"] < bottom]
                if below:
                    standing_position = max(below, key=lambda row: row["eyeElevationMeters"])
                    walkable_floor = standing_position["eyeElevationMeters"] - float(models["attack"].get("defaultCameraHeightMeters", 1.75))
                    probe_elevation = (walkable_floor + bottom) / 2
                    sides = {"attack": state_at(models["attack"], indices["attack"], attack_point, probe_elevation),
                             "defense": state_at(models["defense"], indices["defense"], defense_point, probe_elevation)}
                    if sides["attack"]["filled"] or sides["defense"]["filled"]:
                        overhead.append({"parent": record["wallId"], "assembly": assembly, "sourceObject": station.get("sourceObject"), "sourceRole": "overhead",
                                         "measuredBottomBucket": round(bottom, 1), "measuredBottomMeters": bottom, "walkableFloorElevationMeters": walkable_floor,
                                         "probeElevationMeters": probe_elevation, "standingEyeInsideGap": True,
                                         "stationIndex": station_index, "svg": attack_point.tolist(), "retainedStandingPositions": [standing_position], "sides": sides})

    fragments = []
    for side, parents in eye_states.items():
        for parent, rows in parents.items():
            rows.sort(key=lambda row: row["distance"])
            if not any(row["filled"] for row in rows) or all(row["filled"] for row in rows):
                continue
            runs, current = [], [rows[0]]
            for row in rows[1:]:
                if row["filled"] == current[-1]["filled"]:
                    current.append(row)
                else:
                    runs.append(current); current = [row]
            runs.append(current)
            narrow = [run for run in runs if not run[0]["filled"] and run[-1]["distance"] - run[0]["distance"] <= 4.0]
            if len(runs) >= 3 and narrow:
                fragments.append({"side": side, "parent": parent, "stations": len(rows), "transitions": len(runs) - 1, "narrowOpenRuns": len(narrow),
                                  "sampleOpenRuns": [{"from": run[0]["svg"], "to": run[-1]["svg"], "eye": run[0]["eye"]} for run in narrow[:5]]})
    grouped_gaps = group_rows(gaps, ["parent", "assembly", "gapBucket", "sourceRole", "navigationPassageAbsent"])
    grouped_overhead = group_rows(overhead, ["parent", "assembly", "measuredBottomBucket"])
    families = candidate_families(gaps)
    return {"map": map_name, "status": status, "inputSha256": fingerprints, "fingerprintChecks": checks,
            "sourceRemeasurement": {"used": current_source is not None,
                                    "unresolvedCandidateSections": unresolved_source,
                                    "unresolvedCountsByReason": dict(sorted(Counter(row["reason"] for row in unresolved_source).items()))},
            "standingDomain": "retained-ground-standing-triangles" if attack_standing is not None else "unresolved-no-retained-standing-triangles",
            "coverage": {"profileRecords": len(profile["records"]), "stations": sum(len(row["stations"]) for row in profile["records"]), "assetSides": ["attack", "defense"]},
            "counts": {"rawFilledMeasuredGapGroups": len(grouped_gaps), "rawFilledMeasuredGapInstances": len(gaps),
                       "standingOpeningFamilies": len(families), "standingOpeningStations": sum(row["stationCount"] for row in families),
                       "overheadBelowBottomGroups": len(grouped_overhead), "fragmentedParents": len(fragments)},
            "standingOpeningFamilies": families, "filledMeasuredGaps": grouped_gaps,
            "overheadBelowMeasuredBottom": grouped_overhead, "fragmentedParents": fragments}


def validation_breeze(current_result, manifest):
    review_path = Path("scripts/data/breeze-covered-openings-2026-09-13.json")
    review = read(review_path)
    profile_path = PROFILE_ROOT / "breeze/local-source-profiles.json"
    before_paths = {side: Path(f"work/breeze-covered-v3/before-{side}.json.gz") for side in ["attack", "defense"]}
    before = analyze("breeze", profile_path, before_paths)
    windows = []
    for window in review["windows"]:
        x0, y0, x1, y1 = window["clipBox"]
        def hits(result):
            rows = []
            for group in result["filledMeasuredGaps"]:
                for sample in group["sampleStations"]:
                    x, y = sample["svg"]
                    if x0 <= x <= x1 and y0 - 1 <= y <= y1 + 1:
                        rows.append(sample)
            return len(rows)
        windows.append({"name": window["name"], "beforeFilledGapSamples": hits(before), "currentFilledGapSamples": hits(current_result)})
    return {"inputSha256": {str(review_path): sha(review_path), **{str(path): sha(path) for path in before_paths.values()}},
            "knownWindows": windows,
            "sensitivityLimit": "Known windows can be missed where frozen station association produced one continuous source band; counts cover only measured gaps represented in the frozen profile."}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument("--output-dir", type=Path, required=True)
    args = parser.parse_args()
    manifest = read(args.manifest)
    args.output_dir.mkdir(parents=True, exist_ok=True)
    results = []
    for map_name, body in sorted(manifest["maps"].items()):
        profile_path = PROFILE_ROOT / map_name / "local-source-profiles.json"
        asset_paths = {side: Path(path) for side, path in body["assetPaths"].items()}
        if not profile_path.exists():
            result = {"map": map_name, "status": "fallback-required", "reason": "Frozen local source profiles absent; current-parent fragmentation can be measured but source gaps cannot be independently classified."}
        else:
            result = analyze(map_name, profile_path, asset_paths, body["assetSha256"])
        results.append(result)
        (args.output_dir / f"{map_name}.json").write_text(json.dumps(result, indent=2) + "\n")
        print(map_name, result["status"], result.get("counts", {}), flush=True)
    breeze = next(row for row in results if row["map"] == "breeze")
    validation = validation_breeze(breeze, manifest)
    families = [{"map": row["map"], **family} for row in results for family in row.get("standingOpeningFamilies", [])]
    families.sort(key=lambda row: (-row["stationCount"], -row["gapInstanceCount"], row["map"], row["parent"], row["assembly"]))
    count_keys = ["rawFilledMeasuredGapGroups", "rawFilledMeasuredGapInstances", "standingOpeningFamilies", "standingOpeningStations", "overheadBelowBottomGroups", "fragmentedParents"]
    summary = {"status": "review-only", "manifestSha256": sha(args.manifest), "coverage": {"maps": len(results), "sourceProfileMaps": sum(row["status"].startswith("review-only") for row in results), "fallbackMaps": [row["map"] for row in results if row["status"] == "fallback-required"], "currentSourceRemeasurementMaps": [{"map": row["map"], "failedFrozenChecks": [key for key in ["geometry", "metadata"] if not row["fingerprintChecks"][key]], "unresolvedCountsByReason": row["sourceRemeasurement"]["unresolvedCountsByReason"], "unresolvedCandidateSections": row["sourceRemeasurement"]["unresolvedCandidateSections"]} for row in results if row.get("sourceRemeasurement", {}).get("used")]},
               "counts": {key: sum(row.get("counts", {}).get(key, 0) for row in results) for key in count_keys},
               "maps": [{"map": row["map"], "status": row["status"], **row.get("counts", {})} for row in results], "breezeKnownValidation": validation,
               "candidateFamilyCriteria": "All map+parent+source-assembly families with an adjacent point inside the retained receiver and standing-triangle domain, an eye inside the measured gap, wall clearance at that eye, and the gap filled on both current sides.",
               "standingOpeningFamilies": families,
               "limitations": ["Flags never change wall roles or assets.", "A receiver-backed standing eye inside a source-measured gap is review evidence, not proof that the opening matters to gameplay.", "Station associations can merge a real opening into one continuous source band; known validation reports this sensitivity.", "Point probes test actual current wall intervals on both sides but do not replace rendered sightline review."]}
    (args.output_dir / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")


if __name__ == "__main__":
    main()

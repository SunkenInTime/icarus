"""Inventory suspended standing-top ambiguities across the current map assets."""

import argparse
import gzip
import hashlib
import json
from collections import defaultdict
from pathlib import Path

import numpy as np
import shapely
from shapely.geometry import shape

from compile_reviewed_svg_height_map import polygon


PHYSICAL_ROOT = Path(
    "E:/IcarusWorldAudit/2026-09-06/tactical-visibility-revision/"
    "all-map-standing-surfaces-v9"
)
KNOWN_REVIEWS = [
    Path("scripts/data/reported-sightlines-2026-09-12.json"),
    Path("scripts/data/haven-tactical-sightlines-2026-09-13.json"),
    Path("scripts/data/breeze-gameplay-sightlines-2026-09-13.json"),
    Path("scripts/data/breeze-covered-openings-2026-09-13.json"),
]
CAPSULE_HEIGHT_METERS = 1.96
PLANE_TOLERANCE = 0.02
CLUSTER_DISTANCE_METERS = 0.25


def read(path):
    raw = path.read_bytes()
    return json.loads(gzip.decompress(raw) if path.suffix == ".gz" else raw)


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def review_maps(review):
    if "maps" in review:
        return review["maps"].items()
    return [(review.get("map"), review)]


def known_exclusions():
    known = defaultdict(dict)
    review_inputs = {}
    source_cache = {}
    for path in KNOWN_REVIEWS:
        if not path.exists():
            continue
        review_inputs[str(path)] = sha(path)
        review = read(path)
        for map_name, body in review_maps(review):
            if not map_name or not isinstance(body, dict):
                continue
            source_path = Path(body.get("standingSource", ""))
            domains = {}
            if source_path.exists():
                key = str(source_path)
                if key not in source_cache:
                    source_cache[key] = read(source_path)
                    review_inputs[key] = sha(source_path)
                domains = {row["id"]: row for row in source_cache[key].get("domains", [])}
            for row in body.get("excludedStandingDomains", []):
                full = domains.get(row["id"], row)
                known[map_name][row["id"]] = {
                    "review": str(path),
                    "domain": full,
                    "hasGeometry": "nativeGeometry" in full,
                }
    return known, review_inputs


def plane_height(plane, coordinates):
    coordinates = np.asarray(coordinates)
    return coordinates[:, :2] @ np.asarray(plane[:2]) + float(plane[2])


def body_signal(source):
    rows = source.get("body", {}).get("CollisionResponses", {}).get("ResponseArray", [])
    ignored = {row.get("Channel") for row in rows if row.get("Response", "").endswith("ECR_Ignore")}
    channels = {"Visibility", "Weapon", "WorldStatic"}
    return channels <= ignored, sorted(ignored)


def load_manifest(path):
    manifest = read(path)
    maps = manifest.get("maps", manifest)
    if not isinstance(maps, dict):
        raise ValueError("Manifest must contain a maps object")
    return manifest, maps


def resolve_assets(body):
    paths = body.get("assetPaths", body.get("assets"))
    if not isinstance(paths, dict) or set(paths) != {"attack", "defense"}:
        raise ValueError("Each map needs attack and defense assetPaths")
    return {side: Path(path) for side, path in paths.items()}


def cluster_candidates(map_name, candidates):
    parent = list(range(len(candidates)))
    def find(i):
        while parent[i] != i:
            parent[i] = parent[parent[i]]
            i = parent[i]
        return i
    def union(a, b):
        a, b = find(a), find(b)
        if a != b:
            parent[b] = a
    tree = shapely.STRtree([row["_geometry"] for row in candidates]) if candidates else None
    for one, candidate in enumerate(candidates):
        for two in tree.query(candidate["_geometry"].buffer(CLUSTER_DISTANCE_METERS)):
            two = int(two)
            if two <= one:
                continue
            other = candidates[two]
            if np.max(np.abs(np.asarray(candidate["nativePlane"]) - np.asarray(other["nativePlane"]))) <= PLANE_TOLERANCE and candidate["_geometry"].distance(other["_geometry"]) <= CLUSTER_DISTANCE_METERS:
                union(one, two)
    grouped = defaultdict(list)
    for index in range(len(candidates)):
        grouped[find(index)].append(index)
    clusters = []
    for number, indices in enumerate(sorted(grouped.values(), key=lambda values: candidates[values[0]]["domainId"]), 1):
        cluster_id = f"{map_name}-overhead-{number}"
        for index in indices:
            candidates[index]["clusterId"] = cluster_id
        clusters.append({"id": cluster_id, "domainIds": sorted(candidates[index]["domainId"] for index in indices), "count": len(indices)})
    for row in candidates:
        row.pop("_geometry")
    return clusters


def audit_asset_fallback(map_name, body, known):
    """Less-independent pass for Split, whose reviewed native floor source is absent."""
    asset_paths = resolve_assets(body)
    physical_path = PHYSICAL_ROOT / map_name / "physical-top-build.json"
    alignment_path = Path(f"E:/IcarusWorldAudit/2026-09-06/tactical-alignment-sides-v1/{map_name}.json")
    paths = {"physicalTopBuild": physical_path, "alignment": alignment_path, **{f"asset-{s}": p for s, p in asset_paths.items()}}
    missing = [str(path) for path in paths.values() if not path.exists()]
    if missing:
        return {"map": map_name, "status": "not-covered", "missingInputs": missing}
    hashes = {key: sha(path) for key, path in paths.items()}
    for side, expected in body.get("assetSha256", {}).items():
        if hashes[f"asset-{side}"] != expected:
            raise ValueError((map_name, side, expected, hashes[f"asset-{side}"]))
    assets = {side: read(path) for side, path in asset_paths.items()}
    physical = read(physical_path)
    alignment = np.asarray(read(alignment_path)["nativeToAttackSvg"], dtype=float)
    inverse = np.linalg.inv(alignment[:, :2])
    inverse_transform = [*inverse[0], *inverse[1], *(-inverse @ alignment[:, 2])]
    support_state = {side: {row["id"]: bool(row.get("automaticStandingAllowed")) for row in model["supports"]} for side, model in assets.items()}
    supports = []
    for support in assets["attack"]["supports"]:
        if not support.get("automaticStandingAllowed"):
            continue
        geom = shapely.make_valid(shapely.affinity.affine_transform(polygon(support), inverse_transform))
        svg_plane = np.asarray(support.get("surfacePlane") or [0.0, 0.0, support["surfaceElevationMeters"]], dtype=float)
        native_plane = np.r_[svg_plane[:2] @ alignment[:, :2], float(svg_plane[:2] @ alignment[:, 2] + svg_plane[2])]
        supports.append((support, geom, native_plane))
    support_tree = shapely.STRtree([row[1] for row in supports])
    records = {row.get("supportId"): row for row in physical["records"] if row.get("status") == "added-physical-standing-surface"}
    evidence = {row["id"]: row for row in physical["sourceVolumeEvidence"]}
    candidates = []
    for support, geom, top_plane in supports:
        record = records.get(support["id"])
        if not record:
            continue
        source = evidence.get(record["collision"])
        if not source or "BlockingVolume" not in source.get("kind", ""):
            continue
        body_bottom = float(source["bounds"][0][2])
        lower = []
        for index in support_tree.query(geom, predicate="intersects"):
            lower_support, lower_geom, lower_plane = supports[int(index)]
            if lower_support["id"] == support["id"]:
                continue
            overlap = shapely.intersection(geom, lower_geom, grid_size=1e-8)
            if overlap.area <= 1e-6:
                continue
            heights = plane_height(lower_plane, shapely.get_coordinates(overlap))
            clearance = body_bottom - heights
            if float(clearance.min()) >= CAPSULE_HEIGHT_METERS:
                lower.append({"supportId": lower_support["id"], "overlapSquareMeters": float(overlap.area), "clearanceRangeMeters": [float(clearance.min()), float(clearance.max())], "floorElevationRangeMeters": [float(heights.min()), float(heights.max())]})
        if not lower:
            continue
        pawn_only, ignored = body_signal(source)
        candidates.append({
            "domainId": support["id"], "supportId": support["id"], "sourceCollision": record["collision"],
            "sourceKind": source.get("kind"), "nativePlane": top_plane.tolist(), "bodyBounds": source["bounds"],
            "areaSquareMeters": float(geom.area), "navigationCorroboratingSamples": record.get("navigationCorroboratingSamples"),
            "zeroNavigationCorroboration": record.get("navigationCorroboratingSamples") == 0,
            "pawnOnlyCollisionSignal": pawn_only, "ignoredCollisionChannels": ignored,
            "presentInCurrentSource": None, "automaticInCurrentAssets": {side: support_state[side].get(support["id"], False) for side in assets},
            "lowerEligibleFloors": sorted(lower, key=lambda row: (-row["overlapSquareMeters"], row["supportId"])),
            "classification": "known-reviewed-exclusion" if support["id"] in known else "unresolved-review-needed",
            "_geometry": geom,
        })
    clusters = cluster_candidates(map_name, candidates)
    cluster_sizes = {row["id"]: row["count"] for row in clusters}
    for row in candidates:
        row["highPriorityReview"] = row["zeroNavigationCorroboration"] and row["pawnOnlyCollisionSignal"] and cluster_sizes[row["clusterId"]] > 1
    candidates.sort(key=lambda row: (not row["zeroNavigationCorroboration"], not row["pawnOnlyCollisionSignal"], row["domainId"]))
    return {
        "map": map_name, "status": "covered-with-asset-fallback", "inputSha256": {str(paths[key]): value for key, value in hashes.items()},
        "coverage": {"sourceDomains": None, "physicalBuildRecords": len(physical["records"]), "assetSides": sorted(assets), "sourceComparisonIncluded": False},
        "summary": {"candidates": len(candidates), "knownReviewed": 0, "unresolved": len(candidates), "zeroNavigation": sum(row["zeroNavigationCorroboration"] for row in candidates), "pawnOnlySignal": sum(row["pawnOnlyCollisionSignal"] for row in candidates), "highPriorityReview": sum(row["highPriorityReview"] for row in candidates)},
        "knownValidation": {"expectedIds": sorted(known), "detectedIds": [], "missedIds": sorted(known), "unavailableGeometryIds": sorted(known)},
        "candidates": candidates, "clusters": clusters,
        "independenceLimitation": "No reviewed native regional-floor source or whole-domain comparison exists. Lower domains are derived from current attack asset supports and inverse alignment, so this detects current overlap behavior but cannot independently validate source-floor retention.",
    }


def audit_map(map_name, body, known):
    if not body.get("sourcePath"):
        return audit_asset_fallback(map_name, body, known)
    source_path = Path(body["sourcePath"])
    asset_paths = resolve_assets(body)
    physical_path = Path(body.get("physicalTopBuildPath", PHYSICAL_ROOT / map_name / "physical-top-build.json"))
    paths = {"source": source_path, "physicalTopBuild": physical_path, **{f"asset-{s}": p for s, p in asset_paths.items()}}
    if body.get("sourceComparisonPath"):
        paths["sourceComparison"] = Path(body["sourceComparisonPath"])
    missing = [str(path) for path in paths.values() if not path.exists()]
    if missing:
        return {"map": map_name, "status": "not-covered", "missingInputs": missing}
    hashes = {key: sha(path) for key, path in paths.items()}
    if hashes["source"] != body.get("sourceSha256"):
        raise ValueError((map_name, "source", body.get("sourceSha256"), hashes["source"]))
    for side, expected in body.get("assetSha256", {}).items():
        if hashes[f"asset-{side}"] != expected:
            raise ValueError((map_name, side, expected, hashes[f"asset-{side}"]))

    source = read(source_path)
    physical = read(physical_path)
    assets = {side: read(path) for side, path in asset_paths.items()}
    current = {row["id"]: row for row in source["domains"]}
    universe = dict(current)
    unavailable_known = []
    for domain_id, evidence in known.items():
        if evidence["hasGeometry"]:
            universe.setdefault(domain_id, evidence["domain"])
        elif domain_id not in universe:
            unavailable_known.append(domain_id)

    physical_records = [row for row in physical["records"] if row.get("status") == "added-physical-standing-surface"]
    source_evidence = {row["id"]: row for row in physical["sourceVolumeEvidence"]}
    support_state = {
        side: {row["id"]: bool(row.get("automaticStandingAllowed")) for row in model["supports"]}
        for side, model in assets.items()
    }

    floors, floor_shapes = [], []
    for row in current.values():
        if "nativeGeometry" not in row or "nativePlane" not in row:
            continue
        geom = shape(row["nativeGeometry"])
        if geom.is_empty:
            continue
        floors.append(row)
        floor_shapes.append(geom)
    floor_tree = shapely.STRtree(floor_shapes)

    candidates = []
    for domain_id, domain in universe.items():
        if "nativeGeometry" not in domain or "nativePlane" not in domain:
            continue
        collision = domain.get("sourceCollision")
        source_row = source_evidence.get(collision)
        if not source_row or "BlockingVolume" not in source_row.get("kind", ""):
            continue
        plane = np.asarray(domain["nativePlane"], dtype=float)
        matches = [row for row in physical_records if row["collision"] == collision]
        if not matches:
            continue
        geom = shape(domain["nativeGeometry"])
        point = geom.representative_point()
        reference_top = float(plane[:2] @ [point.x, point.y] + plane[2])
        record = min(matches, key=lambda row: abs(float(np.asarray(row["nativeSurfacePlane"])[:2] @ [point.x, point.y] + row["nativeSurfacePlane"][2]) - reference_top))
        record_plane = np.asarray(record["nativeSurfacePlane"], dtype=float)
        if abs(float(record_plane[:2] @ [point.x, point.y] + record_plane[2]) - reference_top) > PLANE_TOLERANCE:
            continue
        body_bottom = float(source_row["bounds"][0][2])
        lower = []
        for index in floor_tree.query(geom, predicate="intersects"):
            floor = floors[index]
            if floor["id"] == domain_id:
                continue
            overlap = geom.intersection(floor_shapes[index])
            if overlap.area <= 1e-6:
                continue
            coordinates = shapely.get_coordinates(overlap)
            lower_height = plane_height(floor["nativePlane"], coordinates)
            clearance = body_bottom - lower_height
            if float(clearance.min()) < CAPSULE_HEIGHT_METERS:
                continue
            lower.append({
                "domainId": floor["id"],
                "overlapSquareMeters": float(overlap.area),
                "clearanceRangeMeters": [float(clearance.min()), float(clearance.max())],
                "floorElevationRangeMeters": [float(lower_height.min()), float(lower_height.max())],
            })
        if not lower:
            continue
        pawn_only, ignored = body_signal(source_row)
        known_row = known.get(domain_id)
        candidates.append({
            "domainId": domain_id,
            "supportId": record.get("supportId"),
            "sourceCollision": collision,
            "sourceKind": source_row.get("kind"),
            "nativePlane": domain["nativePlane"],
            "bodyBounds": source_row["bounds"],
            "areaSquareMeters": domain.get("areaSquareMeters", float(geom.area)),
            "navigationCorroboratingSamples": record.get("navigationCorroboratingSamples"),
            "zeroNavigationCorroboration": record.get("navigationCorroboratingSamples") == 0,
            "pawnOnlyCollisionSignal": pawn_only,
            "ignoredCollisionChannels": ignored,
            "presentInCurrentSource": domain_id in current,
            "automaticInCurrentAssets": {side: support_state[side].get(record.get("supportId"), False) for side in assets},
            "lowerEligibleFloors": sorted(lower, key=lambda row: (-row["overlapSquareMeters"], row["domainId"])),
            "classification": "known-reviewed-exclusion" if known_row else "unresolved-review-needed",
            **({"knownReview": known_row["review"]} if known_row else {}),
            "_geometry": geom,
        })

    clusters = cluster_candidates(map_name, candidates)
    cluster_sizes = {row["id"]: row["count"] for row in clusters}
    for row in candidates:
        row["highPriorityReview"] = row["classification"] == "unresolved-review-needed" and row["zeroNavigationCorroboration"] and row["pawnOnlyCollisionSignal"] and cluster_sizes[row["clusterId"]] > 1
    candidates.sort(key=lambda row: (row["classification"], not row["zeroNavigationCorroboration"], not row["pawnOnlyCollisionSignal"], row["domainId"]))
    detected_known = sorted(row["domainId"] for row in candidates if row["classification"] == "known-reviewed-exclusion")
    expected_known = sorted(known)
    return {
        "map": map_name,
        "status": "covered",
        "inputSha256": {str(paths[key]): value for key, value in hashes.items()},
        "coverage": {
            "sourceDomains": len(current),
            "physicalBuildRecords": len(physical["records"]),
            "assetSides": sorted(assets),
            "sourceComparisonIncluded": "sourceComparison" in paths,
        },
        "summary": {
            "candidates": len(candidates),
            "knownReviewed": len(detected_known),
            "unresolved": sum(row["classification"] == "unresolved-review-needed" for row in candidates),
            "zeroNavigation": sum(row["zeroNavigationCorroboration"] for row in candidates),
            "pawnOnlySignal": sum(row["pawnOnlyCollisionSignal"] for row in candidates),
            "highPriorityReview": sum(row["highPriorityReview"] for row in candidates),
        },
        "knownValidation": {
            "expectedIds": expected_known,
            "detectedIds": detected_known,
            "missedIds": sorted(set(expected_known) - set(detected_known)),
            "unavailableGeometryIds": sorted(unavailable_known),
        },
        "candidates": candidates,
        "clusters": clusters,
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument("--output-dir", type=Path, required=True)
    args = parser.parse_args()
    manifest, maps = load_manifest(args.manifest)
    known, review_inputs = known_exclusions()
    results = []
    args.output_dir.mkdir(parents=True, exist_ok=True)
    for map_name in sorted(maps):
        result = audit_map(map_name, maps[map_name], known.get(map_name, {}))
        results.append(result)
        (args.output_dir / f"{map_name}.json").write_text(json.dumps(result, indent=2) + "\n")
        print(map_name, result["status"], result.get("summary", {}), flush=True)
    summary = {
        "status": "review-only",
        "manifest": str(args.manifest),
        "manifestSha256": sha(args.manifest),
        "knownReviewInputSha256": review_inputs,
        "criteria": {
            "minimumCapsuleClearanceMeters": CAPSULE_HEIGHT_METERS,
            "planeTolerance": PLANE_TOLERANCE,
            "clusterDistanceMeters": CLUSTER_DISTANCE_METERS,
            "required": "An added physical top from a BlockingVolume overlaps a retained lower source floor with capsule clearance below the collision body's bottom.",
            "rankingSignals": ["zero navigation corroboration", "pawn-only collision response pattern", "coplanar adjacent cluster"],
        },
        "coverage": {"requestedMaps": len(maps), "coveredMaps": sum(row["status"].startswith("covered") for row in results), "independentSourceMaps": sum(row["status"] == "covered" for row in results), "assetFallbackMaps": sum(row["status"] == "covered-with-asset-fallback" for row in results)},
        "counts": {
            "candidates": sum(row.get("summary", {}).get("candidates", 0) for row in results),
            "knownReviewed": sum(row.get("summary", {}).get("knownReviewed", 0) for row in results),
            "unresolved": sum(row.get("summary", {}).get("unresolved", 0) for row in results),
            "detectorMisses": sum(len(row.get("knownValidation", {}).get("missedIds", [])) for row in results),
        },
        "maps": [{"map": row["map"], "status": row["status"], **row.get("summary", {}), "detectorMisses": row.get("knownValidation", {}).get("missedIds", [])} for row in results],
        "limitations": [
            "Candidates remain eligible; this audit never edits assets or source decisions.",
            "A suspended blocking top can be a legitimate roof, boost, or ability-accessible surface. Every unresolved candidate needs gameplay review.",
            "The detector requires overlap with a retained lower standing domain and therefore misses overhead ambiguity where the lower floor is absent from the reviewed source.",
            "Collision response and navigation are ranking signals, not exclusion rules.",
            "Coplanar clustering uses source planes and native-domain proximity; it does not prove shared gameplay purpose.",
        ],
    }
    (args.output_dir / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")


if __name__ == "__main__":
    main()

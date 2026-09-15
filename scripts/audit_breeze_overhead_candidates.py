"""Inventory ambiguous Breeze overhead standing tops without changing assets."""

import argparse
import hashlib
import json
from pathlib import Path

import shapely
from shapely.geometry import shape


DEFAULT_RETAINED = Path("work/breeze-gameplay-v3/source/regional-floors.json")
DEFAULT_BEFORE = Path("work/breeze-all-reviewed-v2/regional-floors.json")
DEFAULT_PHYSICAL = Path(
    "E:/IcarusWorldAudit/2026-09-06/tactical-visibility-revision/"
    "all-map-standing-surfaces-v9/breeze/physical-top-build.json"
)
EXPECTED_SHA256 = {
    "retainedStandingSource": "99ebcb19a44bcae74b1901366be0f3c54c8c0a213fa56cb8853bce031c0b2c3b",
    "beforeStandingSource": "5721ee9799ce5e32ae10cf46107282e0a0b6f7f1c32fbc1db90edb57652185c0",
    "physicalTopBuild": "168923758c071f1917a87be429ce57dfde4b756766a134e1c63a7475068031d9",
}
KNOWN_REVIEWED_DOMAINS = {"volume-583-0"}
KNOWN_REPORTED_DOMAINS = {"volume-387-0", "volume-388-0"}
PLAYER_CAPSULE_HEIGHT_METERS = 1.96
HEIGHT_TOLERANCE_METERS = 0.02
CLUSTER_DISTANCE_METERS = 0.25


def read(path):
    return json.loads(path.read_bytes())


def sha256(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def elevation(domain):
    plane = domain["nativePlane"]
    if abs(plane[0]) > 1e-8 or abs(plane[1]) > 1e-8:
        return None
    return float(plane[2])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--retained", type=Path, default=DEFAULT_RETAINED)
    parser.add_argument("--before", type=Path, default=DEFAULT_BEFORE)
    parser.add_argument("--physical", type=Path, default=DEFAULT_PHYSICAL)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()

    paths = {
        "retainedStandingSource": args.retained,
        "beforeStandingSource": args.before,
        "physicalTopBuild": args.physical,
    }
    actual_hashes = {key: sha256(path) for key, path in paths.items()}
    if actual_hashes != EXPECTED_SHA256:
        raise ValueError({
            key: {"expected": EXPECTED_SHA256[key], "actual": actual_hashes[key]}
            for key in paths if actual_hashes[key] != EXPECTED_SHA256[key]
        })

    retained = read(args.retained)
    before = read(args.before)
    physical = read(args.physical)
    retained_ids = {row["id"] for row in retained["domains"]}
    before_domains = {row["id"]: row for row in before["domains"]}
    evidence = {row["id"]: row for row in physical["sourceVolumeEvidence"]}
    records = [
        row for row in physical["records"]
        if row.get("status") == "added-physical-standing-surface"
    ]

    flat_floors = []
    for floor in retained["domains"]:
        z = elevation(floor)
        if z is not None:
            flat_floors.append((floor, z, shape(floor["nativeGeometry"])))

    candidates = []
    for domain in before["domains"]:
        top = elevation(domain)
        if top is None:
            continue
        matches = [
            row for row in records
            if row["collision"] == domain.get("sourceCollision")
            and abs(float(row["nativeSurfacePlane"][2]) - top) <= HEIGHT_TOLERANCE_METERS
        ]
        record = min(matches, key=lambda row: abs(float(row["nativeSurfacePlane"][2]) - top)) if matches else None
        source = evidence.get(domain.get("sourceCollision"))
        if not record or not source or record.get("navigationCorroboratingSamples") != 0:
            continue
        if "BlockingVolume" not in source.get("kind", ""):
            continue
        body_bottom = float(source["bounds"][0][2])
        top_shape = shape(domain["nativeGeometry"])
        lower = []
        for floor, floor_z, floor_shape in flat_floors:
            if floor["id"] == domain["id"] or floor_z >= body_bottom:
                continue
            overlap = top_shape.intersection(floor_shape).area
            clearance = body_bottom - floor_z
            if overlap > 1e-6 and clearance >= PLAYER_CAPSULE_HEIGHT_METERS:
                lower.append({
                    "domainId": floor["id"],
                    "elevationMeters": floor_z,
                    "overlapSquareMeters": overlap,
                    "clearanceToBodyBottomMeters": clearance,
                })
        if not lower:
            continue
        responses = source.get("body", {}).get("CollisionResponses", {}).get("ResponseArray", [])
        ignored = sorted(row["Channel"] for row in responses if row.get("Response", "").endswith("ECR_Ignore"))
        candidates.append({
            "domainId": domain["id"],
            "supportId": record.get("supportId"),
            "sourceCollision": domain["sourceCollision"],
            "topElevationMeters": top,
            "bodyBottomMeters": body_bottom,
            "navigationCorroboratingSamples": 0,
            "collisionKind": source.get("kind"),
            "collisionProfile": source.get("body", {}).get("CollisionProfileName"),
            "ignoredChannels": ignored,
            "areaSquareMeters": domain.get("areaSquareMeters"),
            "retainedInCurrentSource": domain["id"] in retained_ids,
            "lowerEligibleFloors": sorted(lower, key=lambda row: (-row["overlapSquareMeters"], row["domainId"])),
            "geometry": domain["nativeGeometry"],
        })

    # Connected components of nearby domains at the same elevation. Clustering is
    # descriptive evidence only; membership does not change standing eligibility.
    parent = list(range(len(candidates)))
    shapes = [shape(row["geometry"]) for row in candidates]

    def find(index):
        while parent[index] != index:
            parent[index] = parent[parent[index]]
            index = parent[index]
        return index

    def union(one, two):
        one, two = find(one), find(two)
        if one != two:
            parent[two] = one

    for one in range(len(candidates)):
        for two in range(one + 1, len(candidates)):
            if abs(candidates[one]["topElevationMeters"] - candidates[two]["topElevationMeters"]) <= HEIGHT_TOLERANCE_METERS and shapes[one].distance(shapes[two]) <= CLUSTER_DISTANCE_METERS:
                union(one, two)

    groups = {}
    for index, candidate in enumerate(candidates):
        groups.setdefault(find(index), []).append(candidate["domainId"])
    clusters = []
    for number, members in enumerate(sorted(groups.values(), key=lambda rows: rows[0]), 1):
        cluster_id = f"overhead-cluster-{number}"
        for candidate in candidates:
            if candidate["domainId"] in members:
                candidate["clusterId"] = cluster_id
        clusters.append({"id": cluster_id, "domainIds": sorted(members), "count": len(members)})

    for candidate in candidates:
        candidate.pop("geometry")
        if candidate["domainId"] in KNOWN_REVIEWED_DOMAINS:
            candidate["classification"] = "known-reviewed"
        elif candidate["domainId"] in KNOWN_REPORTED_DOMAINS:
            candidate["classification"] = "known-current-report"
        else:
            candidate["classification"] = "ambiguous-review-needed"
    candidates.sort(key=lambda row: (row["classification"], row["topElevationMeters"], row["domainId"]))

    classes = {
        name: [row for row in candidates if row["classification"] == name]
        for name in ["known-reviewed", "known-current-report", "ambiguous-review-needed"]
    }
    result = {
        "map": "breeze",
        "status": "review-only",
        "inputsSha256": {str(paths[key]): actual_hashes[key] for key in paths},
        "sourcePhysicalReviewHashes": {
            key: physical[key] for key in ["playerSha256", "alignmentSha256", "configSha256"]
        },
        "criteria": {
            "automaticPhysicalTop": "physical build status is added-physical-standing-surface",
            "zeroNavigationCorroboration": True,
            "blockingCollisionKindContains": "BlockingVolume",
            "minimumClearanceMeters": PLAYER_CAPSULE_HEIGHT_METERS,
            "lowerFloorSource": "retained reviewed standing domains",
            "clusterTopToleranceMeters": HEIGHT_TOLERANCE_METERS,
            "clusterDistanceMeters": CLUSTER_DISTANCE_METERS,
        },
        "summary": {name: len(rows) for name, rows in classes.items()},
        "knownReviewed": classes["known-reviewed"],
        "knownCurrentReports": classes["known-current-report"],
        "remainingAmbiguous": classes["ambiguous-review-needed"],
        "clusters": clusters,
        "limitations": [
            "A flag is not an exclusion. Navigation absence and collision naming do not prove gameplay ineligibility.",
            "The inventory detects suspended flat tops overlapping retained lower floors; it does not prove roof access, jump or ability reachability, or tactical intent.",
            "Only the pinned Breeze source revision and physical-standing build are covered.",
            "Sloped overhead faces and ambiguity without an overlapping retained floor are outside this diagnostic.",
        ],
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps(result["summary"], sort_keys=True))


if __name__ == "__main__":
    main()

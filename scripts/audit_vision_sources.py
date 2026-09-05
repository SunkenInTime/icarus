"""Inventory the 3D evidence available in an FModel JSON export.

Only reads named map-level files and the mesh JSON files they reference.
Does not infer visibility from a missing override or a movement collider.
"""

import argparse
from collections import Counter
import hashlib
import json
from pathlib import Path


def load(path):
    data = path.read_bytes()
    return json.loads(data), hashlib.sha256(data).hexdigest()


def inspect_mesh(path):
    if not path.is_file():
        return {"status": "missing-mesh-json"}
    objects, digest = load(path)
    bodies = []
    for obj in objects:
        if obj.get("Type") != "BodySetup":
            continue
        props = obj.get("Properties", {})
        agg = props.get("AggGeom", {})
        bodies.append({
            "name": obj.get("Name"),
            "collisionTraceFlag": props.get("CollisionTraceFlag", "inherited"),
            "defaultInstance": props.get("DefaultInstance", {}),
            "simplePrimitiveCounts": {key: len(value) for key, value in agg.items()
                if isinstance(value, list)},
            "convexVertexCount": sum(len(e.get("VertexData", [])) for e in agg.get("ConvexElems", [])),
            "cookedCollisionFormats": list(obj.get("CookedFormatData", {})),
        })
    lods = [lod for obj in objects if obj.get("Type") == "StaticMesh"
        for lod in obj.get("RenderData", {}).get("LODs", [])]
    return {
        "status": "inspected", "sha256": digest, "bodies": bodies,
        "renderVertexCountMetadata": sum((lod.get("PositionVertexBuffer") or {}).get("NumVertices", 0) for lod in lods),
        "renderPositionBufferKeys": sorted({key for lod in lods
            for key in (lod.get("PositionVertexBuffer") or {})}),
        "renderLodKeys": sorted({key for lod in lods for key in lod}),
        "hasComplexAsSimple": any("UseComplexAsSimple" in b["collisionTraceFlag"] for b in bodies),
        "hasReadableSimpleConvexVertices": any(b["convexVertexCount"] > 0 for b in bodies),
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--content-root", required=True, type=Path)
    parser.add_argument("--map-directory", default="Maps/Bonsai")
    parser.add_argument("--levels", nargs="+", default=[
        "Bonsai_BVPawn.json", "Bonsai_Greybox.json", "Bonsai_Art_Mid.json", "Bonsai_Gameplay.json"])
    parser.add_argument("--output", type=Path, default=Path("build/vision-audit/split-sources.json"))
    args = parser.parse_args()
    root = args.content_root.resolve()
    components, meshes, sources = [], {}, {}
    for level in args.levels:
        path = (root / args.map_directory / level).resolve()
        if not path.is_relative_to(root):
            raise ValueError("Map-level path leaves the content root")
        objects, digest = load(path)
        sources[str(path.relative_to(root))] = digest
        for obj in objects:
            if obj.get("Type") != "StaticMeshComponent":
                continue
            props = obj.get("Properties", {})
            body = props.get("BodyInstance", {})
            visibility = next((r.get("Response", "inherited") for r in
                body.get("CollisionResponses", {}).get("ResponseArray", [])
                if r.get("Channel") == "Visibility"), "inherited")
            mesh_ref = (props.get("StaticMesh") or {}).get("ObjectPath")
            mesh_key = None
            if mesh_ref and mesh_ref.startswith("/Game/"):
                mesh_key = mesh_ref[6:].rsplit(".", 1)[0] + ".json"
                mesh_path = (root / mesh_key).resolve()
                if not mesh_path.is_relative_to(root):
                    raise ValueError("Mesh reference leaves the content root")
                if mesh_key not in meshes:
                    meshes[mesh_key] = inspect_mesh(mesh_path)
            components.append({
                "level": level, "name": obj.get("Name"), "outer": obj.get("Outer"),
                "mesh": mesh_key,
                "meshResolution": "explicit" if mesh_key else
                    "explicit-none" if "StaticMesh" in props else "requires-inherited-defaults",
                "collisionEnabled": body.get("CollisionEnabled", "inherited"),
                "profile": body.get("CollisionProfileName", "inherited"),
                "explicitVisibilityResponse": visibility,
                "relativeLocation": props.get("RelativeLocation"),
                "relativeRotation": props.get("RelativeRotation"),
                "relativeScale3D": props.get("RelativeScale3D"),
            })
    summary = {
        "selectedLevels": len(sources), "staticMeshComponents": len(components),
        "uniqueExplicitMeshReferences": len(meshes),
        "componentsRequiringInheritedMeshDefaults": sum(c["meshResolution"] == "requires-inherited-defaults" for c in components),
        "componentsWithExplicitNullMesh": sum(c["meshResolution"] == "explicit-none" for c in components),
        "explicitVisibilityResponses": dict(Counter(c["explicitVisibilityResponse"] for c in components)),
        "missingMeshJson": sum(m["status"] != "inspected" for m in meshes.values()),
        "meshesWithReadableSimpleConvexVertices": sum(m.get("hasReadableSimpleConvexVertices", False) for m in meshes.values()),
        "meshesRequiringComplexAsSimple": sum(m.get("hasComplexAsSimple", False) for m in meshes.values()),
        "renderPositionBufferKeys": sorted({key for m in meshes.values() for key in m.get("renderPositionBufferKeys", [])}),
    }
    report = {"schemaVersion": 1, "status": "inventory-only", "summary": summary,
        "limitations": [
            "Selected files are not proof that every component is active in the current game mode.",
            "Inherited mesh defaults, attachment transforms, collision profiles, and game-specific trace channels need resolution.",
            "Visibility collision response is not proof of player-camera visual occlusion; materials and render geometry also matter.",
            "Simple convex geometry cannot substitute for a required complex triangle mesh.",
            "This inventory performs no ray casts and certifies no gameplay sightlines.",
        ], "sourceHashes": sources, "components": components, "meshes": meshes}
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, indent=2), encoding="utf-8")
    print(json.dumps(summary, indent=2))


if __name__ == "__main__":
    main()

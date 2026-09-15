"""Install the independently verified standing-height packs without rebaking them."""
import argparse
import gzip
import hashlib
import json
import shutil
import struct
from pathlib import Path


def sha(data):
    return hashlib.sha256(data).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--audit-root", type=Path, required=True)
    parser.add_argument("--output", type=Path, default=Path("assets/maps/world"))
    args = parser.parse_args()
    root, output = args.audit_root, args.output
    selector = root / "completeness/combined-manifest-release-inputs-v2.json"
    sources = json.loads(selector.read_text())
    if len(sources) != 13 or len({s["map"] for s in sources}) != 13:
        raise ValueError("Expected all 13 unique maps")
    output.mkdir(parents=True, exist_ok=True)
    maps = {}
    for source in sources:
        name = source["map"]
        folder = root / "compact-prototype/all-map-height-scoped-v2" / name
        completion = json.loads((folder / "completion.json").read_text())
        summary = json.loads((folder / "summary.json").read_text())
        if completion["status"] != "passed":
            raise ValueError(f"Unverified pack: {name}")
        pack = folder / f"{name}.height.bin.gz"
        compressed = pack.read_bytes()
        if sha(compressed) != completion["packSha256"]:
            raise ValueError(f"Pack hash mismatch: {name}")
        raw = gzip.decompress(compressed)
        magic, length = struct.unpack_from("<4sI", raw)
        if magic != b"IHD1" or len(raw) != completion["rawBytes"]:
            raise ValueError(f"Invalid pack: {name}")
        header = json.loads(raw[8:8 + length])
        if header["map"] != name or header["sourceGeometrySha256"] != source["geometrySha256"]:
            raise ValueError(f"Source mismatch: {name}")
        metadata_bytes = (Path(source["combinedWorldFolder"]) / "geometry.json").read_bytes()
        if sha(metadata_bytes) != source["metadataSha256"]:
            raise ValueError(f"Projection metadata mismatch: {name}")
        metadata = json.loads(metadata_bytes)
        legacy = json.loads((root / f"candidate-world-final/{name}_visibility.manifest.json").read_text())
        nav_file = root / f"candidate-world-final/{name}_navigation.json.gz"
        nav = nav_file.read_bytes()
        if sha(nav) != legacy["navigationAsset"]["sha256"]:
            raise ValueError(f"Navigation hash mismatch: {name}")
        nav_json = json.loads(gzip.decompress(nav))
        if nav_json["map"] != name or nav_json["observerHeightCm"] != 175:
            raise ValueError(f"Navigation metadata mismatch: {name}")
        maps[name] = {
            "pack": pack.name, "packSha256": sha(compressed),
            "compressedBytes": len(compressed), "rawSha256": sha(raw), "rawBytes": len(raw),
            "navigation": nav_file.name, "navigationSha256": sha(nav), "navigationBytes": len(nav),
            "sourceGeometrySha256": source["geometrySha256"],
            "policySha256": header["policySha256"],
            "heightDomainMeters": header["heightDomainMeters"],
            "observerHeightCm": 175, "defaultFloorElevationCm": nav_json["defaultFloorElevationCm"],
            "menuElevationsCm": legacy["menuElevationsCm"], "uiTransform": metadata["uiTransform"],
            "retainedFaces": header["retainedFaces"],
        }
        shutil.copyfile(pack, output / pack.name)
        shutil.copyfile(nav_file, output / nav_file.name)
        print(f"{name}: {len(compressed):,} height + {len(nav):,} navigation bytes", flush=True)
    catalog = {"version": 1, "format": "icarus-height-assets-v1", "sourceSelectorSha256": sha(selector.read_bytes()), "maps": maps}
    (output / "height_catalog.json").write_text(json.dumps(catalog, indent=2) + "\n", encoding="utf-8")
    print(f"Installed {len(maps)} maps; {sum(m['compressedBytes'] + m['navigationBytes'] for m in maps.values()):,} bytes")


if __name__ == "__main__":
    main()

"""Compose offline renderer outputs into numbered sheets and paired evidence.

Requires Pillow. Images use only real SVG/native-rendered evidence. A missing
candidate remains visibly missing; it is never replaced by a baseline copy.
"""
import argparse
import json
import math
from collections import defaultdict
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont


def font(size):
    return ImageFont.truetype("C:/Windows/Fonts/segoeui.ttf", size)


def save_png(image, destination):
    temporary = destination.with_suffix(".pending.png")
    image.save(temporary)
    temporary.replace(destination)


def paginated_sheets(sheet, output, stem, case_count, cell_height=710):
    """Two rows per page keep labels readable in review tools that resize images."""
    rows = math.ceil(case_count / 3)
    for first in range(0, rows, 2):
        count = min(2, rows - first)
        page = Image.new("RGB", (sheet.width, 90 + count * cell_height), "#17171d")
        page.paste(sheet.crop((0, 0, sheet.width, 90)), (0, 0))
        top = 90 + first * cell_height
        page.paste(sheet.crop((0, top, sheet.width, top + count * cell_height)), (0, 90))
        save_png(page, output / f"{stem}-page-{first // 2 + 1:02d}.png")


def fit(path, size):
    image = Image.open(path).convert("RGB")
    image.thumbnail(size, Image.Resampling.LANCZOS)
    result = Image.new("RGB", size, "#101014")
    result.paste(image, ((size[0] - image.width) // 2, (size[1] - image.height) // 2))
    return result


def closeup(case, output):
    """Keep source 2 px/SVG density, enlarging small crops without smoothing."""
    paths = [case["before"]] + ([case["after"]] if case["after"] else [])
    boxes = []
    for path in paths:
        alpha = Image.open(path.replace("-overlay.png", "-visibility.png")).getchannel("A")
        box = alpha.point(lambda value: 255 if value > 16 else 0).getbbox()
        if box:
            boxes.append(box)
    source = Image.open(case["before"]).convert("RGB")
    box = (max(0, min(b[0] for b in boxes) - 24),
           max(0, min(b[1] for b in boxes) - 24),
           min(source.width, max(b[2] for b in boxes) + 24),
           min(source.height, max(b[3] for b in boxes) + 24)) if boxes else (0, 0, source.width, source.height)
    zoom = 2 if max(box[2] - box[0], box[3] - box[1]) < 800 else 1
    size = ((box[2] - box[0]) * zoom, (box[3] - box[1]) * zoom)
    panel_w = max(size[0], 600)
    image = Image.new("RGB", (2 * panel_w, 110 + size[1]), "#17171d")
    draw = ImageDraw.Draw(image)
    draw.text((12, 6), f"{case['map']} / {case['side']} / {case['id']}", font=font(25), fill="white")
    note = case.get('scopeLabel', 'Same crop; nearest-neighbor enlargement only.')
    draw.text((12, 40), f"{2 * zoom} px/SVG unit. {note}", font=font(18), fill="#bcbcc6")
    draw.text((12, 74), "Before", font=font(21), fill="white")
    draw.text((panel_w + 12, 74), "Experimental candidate" if case["after"] else "Candidate unavailable", font=font(21), fill="white")
    for i, path in enumerate(paths):
        crop = Image.open(path).convert("RGB").crop(box).resize(size, Image.Resampling.NEAREST)
        image.paste(crop, (i * panel_w, 110))
    save_png(image, output)
    return {"sourcePixelCrop": box, "pixelsPerSvgUnit": 2 * zoom}


def split_line_probe(folder):
    """Known authored corridor line; reports observations, not desired answers."""
    rows = []
    for state in ("before", "after"):
        prefix = folder / "split" / "attack" / f"annotated-deadlock-{state}"
        clipped_path = Path(str(prefix) + "-visibility.png")
        if not clipped_path.exists():
            continue
        clipped = Image.open(clipped_path)
        unclipped = Image.open(str(prefix) + "-unclipped.png")
        for x in (246, 250, 260, 270, 280, 290):
            def first(image):
                return next(((y + .5) / 2 for y in range(158, 185)
                             if image.getpixel((round(x * 2), y))[3] >= 128), None)
            rows.append({"state": state, "svgX": x,
                         "authoredWallCenterlineSvgY": 83.9221,
                         "firstClippedPixelCenterSvgY": first(clipped),
                         "firstUnclippedPixelCenterSvgY": first(unclipped)})
    if rows:
        (folder / "split-deadlock-line-probe.json").write_text(json.dumps({
            "scope": "Authored horizontal upper corridor line. First pixel with alpha >=128 in direct SVG render. Source samples are 0.5 SVG units apart; this is a diagnostic, not ground-truth acceptance.",
            "rows": rows,
        }, indent=2))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("folder", type=Path)
    args = parser.parse_args()
    manifest = json.loads((args.folder / "manifest.json").read_text())
    groups = defaultdict(list)
    for case in manifest["cases"]:
        groups[case["map"], case["side"]].append(case)
    output = args.folder / "sheets"
    output.mkdir(exist_ok=True)
    index = []
    for (map_name, side), cases in groups.items():
        columns = 3
        cell_w, cell_h = 640, 710
        sheet = Image.new("RGB", (columns * cell_w, 90 + math.ceil(len(cases) / columns) * cell_h), "#17171d")
        draw = ImageDraw.Draw(sheet)
        candidate_sheet = Image.new("RGB", sheet.size, "#17171d") if any(c['after'] for c in cases) else None
        candidate_draw = ImageDraw.Draw(candidate_sheet) if candidate_sheet else None
        draw.text((20, 12), f"{map_name.upper()} / {side} / fixed native standing poses", font=font(27), fill="white")
        draw.text((20, 52), "Baseline. Inspect boundaries and floor changes; these images do not certify the game.", font=font(18), fill="#bcbcc6")
        if candidate_draw:
            candidate_draw.text((20, 12), f"{map_name.upper()} / {side} / experimental candidate", font=font(27), fill="white")
            candidate_draw.text((20, 52), cases[0].get('scopeLabel', 'Saved marker positions fixed. Inspect against matching baseline case numbers.'), font=font(18), fill="#bcbcc6")
        for i, case in enumerate(cases):
            x, y = (i % columns) * cell_w, 90 + (i // columns) * cell_h
            sheet.paste(fit(case["before"], (cell_w, 640)), (x, y + 65))
            draw.text((x + 12, y + 4), f"{i + 1:02d}  {case['id']}", font=font(22), fill="white")
            draw.text((x + 12, y + 35), case["category"], font=font(16), fill="#bcbcc6")
            if candidate_sheet:
                if case['after']:
                    candidate_sheet.paste(fit(case['after'], (cell_w, 640)), (x, y + 65))
                candidate_draw.text((x + 12, y + 4), f"{i + 1:02d}  {case['id']}", font=font(22), fill="white")
                candidate_draw.text((x + 12, y + 35), case.get('candidateFloorMode') or case['candidateStatus'], font=font(16), fill="#bcbcc6")
            paired = Image.new("RGB", (1900, 1030), "#17171d")
            pd = ImageDraw.Draw(paired)
            pd.text((20, 8), f"{map_name} / {side} / {case['id']}", font=font(26), fill="white")
            pd.text((20, 43), "Before", font=font(21), fill="white")
            pd.text((970, 43), "Experimental candidate" if case["after"] else "Candidate unavailable", font=font(21), fill="white")
            paired.paste(fit(case["before"], (950, 950)), (0, 80))
            if case["after"]:
                paired.paste(fit(case["after"], (950, 950)), (950, 80))
            else:
                pd.text((990, 500), "No candidate result for this fixed pose.", font=font(24), fill="#bcbcc6")
            pair_path = output / f"{map_name}-{side}-{i + 1:02d}-{case['id']}.png"
            save_png(paired, pair_path)
            close_path = pair_path.with_stem(pair_path.stem + "-closeup")
            close_info = closeup(case, close_path)
            index.append({"map": map_name, "side": side, "number": i + 1, "id": case["id"], "pairedImage": str(pair_path), "closeupImage": str(close_path), **close_info, "candidateStatus": case["candidateStatus"]})
        # Pasting decoded Pillow images can replace the image core. Recreate the
        # drawing context after every paste so labels cannot target a stale core.
        for target, is_candidate in ((sheet, False), (candidate_sheet, True)):
            if target is None:
                continue
            labels = ImageDraw.Draw(target)
            for i, case in enumerate(cases):
                x, y = (i % columns) * cell_w, 90 + (i // columns) * cell_h
                labels.rectangle((x, y, x + cell_w - 1, y + 64), fill="#17171d")
                labels.text((x + 12, y + 4), f"{i + 1:02d}  {case['id']}", font=font(22), fill="white")
                subtitle = (case.get('candidateFloorMode') or case['candidateStatus']) if is_candidate else case['category']
                labels.text((x + 12, y + 35), subtitle, font=font(16), fill="#bcbcc6")
                label_crop = target.crop((x, y, x + cell_w, y + 35))
                assert label_crop.convert('L').getextrema()[1] > 180, case['id']
        save_png(sheet, output / f"{map_name}-{side}-baseline.png")
        paginated_sheets(sheet, output, f"{map_name}-{side}-baseline", len(cases))
        if candidate_sheet:
            save_png(candidate_sheet, output / f"{map_name}-{side}-candidate.png")
            paginated_sheets(candidate_sheet, output, f"{map_name}-{side}-candidate", len(cases))
    (output / "index.json").write_text(json.dumps(index, indent=2))
    split_line_probe(args.folder)
    print(f"Created {len(groups)} map-side sheets and {len(index)} fixed-pose comparisons in {output}")


if __name__ == "__main__":
    main()

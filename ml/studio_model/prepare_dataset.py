"""Builds a training dataset from real field photos, with draft masks.

Drawing 1,000 masks by hand is days of work. Instead a large, accurate
"teacher" model draws a first draft for every photo, hands are subtracted
the same way the app does it, and you only fix or reject the bad ones.
The small phone model (U²-Netp) then learns from those masks: it inherits
the teacher's quality but stays small and fast enough for the phone.

Teachers:
  isnet    rembg "isnet-general-use" (default; good quality, ~1–3 s/photo CPU)
  birefnet rembg "birefnet-general" (best quality, slow on CPU: use a GPU)
  app      the app's current u2netp.tflite (no extra download; lowest quality,
           only useful to bootstrap or to compare)

Usage:
  python prepare_dataset.py --input /path/to/photos --out dataset
  python prepare_dataset.py --input more_photos --out dataset   # adds, resumes

Output (dataset/):
  images/<id>.jpg       the photo, upright, long side ≤ --max-side
  masks/<id>.png        draft mask: white = product, black = background
  review/<id>.jpg       photo | cut-out, for a quick visual check
  review.html           all drafts, most doubtful first; open in a browser
  manifest.csv          id, source path, teacher, doubt score, hand flag
  rejected.txt          ids to leave out of training (one per line; you edit)

Then follow README.md → "Review the drafts".
"""

from __future__ import annotations

import argparse
import csv
import hashlib
import html
import sys
from pathlib import Path

import numpy as np
from PIL import Image

from common import (
    APP_HAND_MODEL, APP_OBJECT_MODEL, filter_skin_to_hands, largest_component,
    list_images, load_rgb, minmax, resize_map, run_saliency, run_skin,
    tflite_interpreter,
)


class Teacher:
    def __init__(self, name: str):
        self.name = name
        if name == "app":
            self.it = tflite_interpreter(APP_OBJECT_MODEL)
        else:
            from rembg import new_session
            model = {"isnet": "isnet-general-use",
                     "birefnet": "birefnet-general"}[name]
            self.session = new_session(model)

    def mask(self, img: Image.Image) -> np.ndarray:
        """Product probability at full image size, 0..1."""
        if self.name == "app":
            sal = minmax(run_saliency(self.it, img))
            return resize_map(sal, img.size)
        from rembg import remove
        m = remove(img, session=self.session, only_mask=True)
        return np.asarray(m.convert("L"), np.float32) / 255.0


def sample_id(path: Path) -> str:
    """Content hash: the same photo pulled twice is only added once."""
    return hashlib.sha1(path.read_bytes()).hexdigest()[:16]


def doubt_score(mask: np.ndarray, hand: bool) -> float:
    """Higher = more likely to need a fix: lots of in-between values (the
    teacher wasn't sure), a tiny or frame-filling subject, or a hand."""
    unsure = float(((mask > 0.15) & (mask < 0.85)).mean())
    area = float((mask >= 0.5).mean())
    odd_size = 1.0 if area < 0.03 or area > 0.9 else 0.0
    return unsure * 10 + odd_size + (0.5 if hand else 0.0)


def review_image(img: Image.Image, mask: np.ndarray) -> Image.Image:
    """Photo on the left, the cut-out on grey on the right."""
    w, h = img.size
    scale = 640 / max(w, h)
    size = (max(1, round(w * scale)), max(1, round(h * scale)))
    small = img.resize(size, Image.BILINEAR)
    a = Image.fromarray((resize_map(mask, size) * 255).clip(0, 255)
                        .astype(np.uint8))
    grey = Image.new("RGB", size, (128, 128, 128))
    cut = Image.composite(small, grey, a)
    out = Image.new("RGB", (size[0] * 2 + 8, size[1]), (255, 255, 255))
    out.paste(small, (0, 0))
    out.paste(cut, (size[0] + 8, 0))
    return out


def write_review_html(out: Path, rows: list[dict]) -> None:
    rows = sorted(rows, key=lambda r: -float(r["doubt"]))
    cards = []
    for r in rows:
        flag = " · hand removed" if r["hand"] == "1" else ""
        cards.append(
            f'<figure><img loading="lazy" src="review/{r["id"]}.jpg">'
            f'<figcaption><code>{html.escape(r["id"])}</code> · doubt '
            f'{float(r["doubt"]):.2f}{flag}</figcaption></figure>')
    (out / "review.html").write_text(f"""<!doctype html>
<meta charset="utf-8"><title>Mask review</title>
<style>
body{{font:14px system-ui;margin:16px;background:#f4f4f4}}
figure{{display:inline-block;margin:6px;background:#fff;padding:6px;
border-radius:8px;vertical-align:top}}
img{{max-width:600px;display:block}}
code{{user-select:all}}
</style>
<h1>Draft masks ({len(rows)}), most doubtful first</h1>
<p>Left: photo. Right: what the model will learn as "product".
Bad cut-out? Either fix <code>masks/&lt;id&gt;.png</code> (white = product,
black = background) or add the id to <code>rejected.txt</code>.</p>
{''.join(cards)}
""")


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawTextHelpFormatter)
    ap.add_argument("--input", required=True, type=Path)
    ap.add_argument("--out", default=Path("dataset"), type=Path)
    ap.add_argument("--teacher", default="isnet",
                    choices=["isnet", "birefnet", "app"])
    ap.add_argument("--max-side", type=int, default=1280,
                    help="long side of stored photos (training uses 320)")
    ap.add_argument("--no-hand-removal", action="store_true")
    ap.add_argument("--keep-all-blobs", action="store_true",
                    help="don't reduce drafts to their largest object")
    args = ap.parse_args()

    photos = list_images(args.input)
    if not photos:
        sys.exit(f"no photos found under {args.input}")
    for sub in ("images", "masks", "review"):
        (args.out / sub).mkdir(parents=True, exist_ok=True)
    (args.out / "rejected.txt").touch()

    manifest = args.out / "manifest.csv"
    rows: dict[str, dict] = {}
    if manifest.exists():
        with manifest.open() as f:
            rows = {r["id"]: r for r in csv.DictReader(f)}

    teacher = Teacher(args.teacher)
    hands = None if args.no_hand_removal else tflite_interpreter(APP_HAND_MODEL)

    added = skipped = failed = 0
    for i, path in enumerate(photos, 1):
        if i % 25 == 0 or i == len(photos):
            print(f"{i}/{len(photos)} photos  (+{added} new, "
                  f"{skipped} already done, {failed} failed so far)")
        try:
            sid = sample_id(path)
            if sid in rows and (args.out / "masks" / f"{sid}.png").exists():
                skipped += 1
                continue
            img = load_rgb(path, args.max_side)
            mask = teacher.mask(img)

            hand = False
            if hands is not None:
                skin = filter_skin_to_hands(run_skin(hands, img), mask)
                skin_full = resize_map(skin, img.size)
                hand_px = (skin_full > 0.5) & (mask > 0.3)
                hand = bool(hand_px.mean() > 0.004)
                # Hands are never "product": cut them, with a soft edge.
                mask = mask * (1 - np.clip((skin_full - 0.3) / 0.4, 0, 1))
            if not args.keep_all_blobs:
                mask = largest_component(mask)

            img.save(args.out / "images" / f"{sid}.jpg", quality=95)
            Image.fromarray((mask * 255).clip(0, 255).astype(np.uint8)).save(
                args.out / "masks" / f"{sid}.png")
            review_image(img, mask).save(
                args.out / "review" / f"{sid}.jpg", quality=85)
            rows[sid] = {"id": sid, "source": str(path),
                         "teacher": args.teacher,
                         "doubt": f"{doubt_score(mask, hand):.3f}",
                         "hand": "1" if hand else "0"}
            added += 1
        except Exception as e:  # one bad file must not stop a 1,000-photo run
            failed += 1
            print(f"  ! {path}: {e}", file=sys.stderr)

    with manifest.open("w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=["id", "source", "teacher", "doubt",
                                          "hand"])
        w.writeheader()
        w.writerows(rows.values())
    write_review_html(args.out, list(rows.values()))
    print(f"\nDataset: {len(rows)} photos in {args.out}. "
          f"Open {args.out / 'review.html'} to review the drafts.")


if __name__ == "__main__":
    main()

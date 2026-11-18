"""Compares the app's current studio model with a newly trained one.

Runs both .tflite files exactly as the phone does (same input, same
preprocessing) on the validation photos — ones training never saw — and
scores them against the reviewed masks:

  IoU          overall overlap with the true product        (higher better)
  boundary F   how well the outline matches, within ~1%    (higher better)
  leak         share of the cut-out that isn't product:
               hand, table, screen strips                   (lower better)

Usage:
  python evaluate.py --data dataset \
      --old ../../assets/models/u2netp.tflite \
      --new runs/exp1/u2netp_finetuned.tflite --out runs/exp1/eval

Writes per-photo scores (scores.csv) and side-by-side images
(photo | old | new) for the photos where the two differ most, and prints a
SHIP / DON'T SHIP verdict.
"""

from __future__ import annotations

import argparse
import csv
import sys
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw

from common import (
    boundary_f, iou, is_val, leak, load_rgb, minmax, resize_map,
    run_saliency, tflite_interpreter,
)


def predict(it, img: Image.Image) -> np.ndarray:
    # The app min-max normalises the raw map before thresholding at 0.5.
    return resize_map(minmax(run_saliency(it, img)), img.size)


def panel(img: Image.Image, masks: list[np.ndarray], labels: list[str]) -> Image.Image:
    w, h = img.size
    s = 360 / max(w, h)
    size = (max(1, round(w * s)), max(1, round(h * s)))
    small = img.resize(size, Image.BILINEAR)
    tiles = [small]
    for m in masks:
        a = Image.fromarray((resize_map(m, size) >= 0.5).astype(np.uint8) * 255)
        tiles.append(Image.composite(small, Image.new("RGB", size, (128, 128, 128)), a))
    out = Image.new("RGB", ((size[0] + 6) * len(tiles), size[1] + 22), "white")
    d = ImageDraw.Draw(out)
    for i, (t, lab) in enumerate(zip(tiles, ["photo"] + labels)):
        out.paste(t, (i * (size[0] + 6), 22))
        d.text((i * (size[0] + 6) + 4, 4), lab, fill="black")
    return out


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawTextHelpFormatter)
    ap.add_argument("--data", required=True, type=Path)
    ap.add_argument("--old", required=True, type=Path)
    ap.add_argument("--new", required=True, type=Path)
    ap.add_argument("--out", default=Path("eval"), type=Path)
    ap.add_argument("--val-frac", type=float, default=0.15,
                    help="must match the value used for training")
    ap.add_argument("--examples", type=int, default=30)
    args = ap.parse_args()

    rejected = set()
    if (args.data / "rejected.txt").exists():
        rejected = set((args.data / "rejected.txt").read_text().split())
    ids = [p.stem for p in sorted((args.data / "images").glob("*.jpg"))
           if p.stem not in rejected and is_val(p.stem, args.val_frac)
           and (args.data / "masks" / f"{p.stem}.png").exists()]
    if not ids:
        sys.exit("no validation photos found")

    old_it, new_it = tflite_interpreter(args.old), tflite_interpreter(args.new)
    args.out.mkdir(parents=True, exist_ok=True)
    rows = []
    for n, sid in enumerate(ids, 1):
        img = load_rgb(args.data / "images" / f"{sid}.jpg")
        gt = np.asarray(Image.open(args.data / "masks" / f"{sid}.png")
                        .convert("L").resize(img.size), np.float32) / 255
        po, pn = predict(old_it, img), predict(new_it, img)
        rows.append({
            "id": sid,
            "old_iou": iou(po, gt), "new_iou": iou(pn, gt),
            "old_bf": boundary_f(po, gt), "new_bf": boundary_f(pn, gt),
            "old_leak": leak(po, gt), "new_leak": leak(pn, gt),
            "_masks": (img, po, pn),
        })
        if n % 25 == 0:
            print(f"{n}/{len(ids)}")

    with (args.out / "scores.csv").open("w", newline="") as f:
        keys = [k for k in rows[0] if not k.startswith("_")]
        w = csv.DictWriter(f, fieldnames=keys)
        w.writeheader()
        for r in rows:
            w.writerow({k: (f"{r[k]:.4f}" if isinstance(r[k], float) else r[k])
                        for k in keys})

    # Side-by-sides where the models differ most (wins and losses).
    by_diff = sorted(rows, key=lambda r: abs(r["new_iou"] - r["old_iou"]),
                     reverse=True)[: args.examples]
    for r in by_diff:
        img, po, pn = r["_masks"]
        tag = "better" if r["new_iou"] >= r["old_iou"] else "WORSE"
        panel(img, [po, pn], [f"old IoU {r['old_iou']:.2f}",
                              f"new IoU {r['new_iou']:.2f}"]).save(
            args.out / f"{tag}_{r['id']}.jpg", quality=85)

    def mean(k: str) -> float:
        return float(np.mean([r[k] for r in rows]))

    print(f"\n{len(rows)} validation photos (never seen in training)\n")
    print(f"{'':12s}{'old':>8s}{'new':>8s}")
    for name, k, better in [("IoU", "iou", 1), ("boundary F", "bf", 1),
                            ("leak", "leak", -1)]:
        o, n_ = mean(f"old_{k}"), mean(f"new_{k}")
        arrow = "✓" if (n_ - o) * better > 0 else "✗"
        print(f"{name:12s}{o:8.3f}{n_:8.3f}  {arrow}")
    worse = sum(r["new_iou"] < r["old_iou"] - 0.05 for r in rows)
    print(f"\nphotos clearly worse with the new model: {worse}/{len(rows)}")

    ship = (mean("new_iou") > mean("old_iou")
            and mean("new_bf") >= mean("old_bf")
            and mean("new_leak") <= mean("old_leak")
            and worse <= 0.1 * len(rows))
    if ship:
        verdict = "SHIP: copy the new model into assets/models/u2netp.tflite"
    elif worse:
        verdict = (f"DON'T SHIP yet: look at the WORSE_* images in {args.out}; "
                   "fix those masks or add more photos like them, then retrain")
    else:
        verdict = ("DON'T SHIP: the new model isn't clearly better. Train longer, "
                   "or add more (and more varied) reviewed photos")
    print("\nVERDICT:", verdict)


if __name__ == "__main__":
    main()

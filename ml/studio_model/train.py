"""Fine-tunes U²-Netp (the app's studio cut-out model) on your own photos.

Starts from the public U²-Netp weights the app ships today and teaches it
your products: packs held in a hand, labels, packs lying flat, shelves and
screens around them. The architecture, input size and preprocessing stay
exactly the same, so the exported .tflite drops into the app with no code
change.

Usage (GPU strongly recommended; see README.md / train_colab.ipynb):
  python train.py --data dataset --repo U-2-Net --weights u2netp.pth \
      --out runs/exp1 [--backgrounds backgrounds/] [--epochs 60]

Writes runs/<exp>/best.pth (highest validation IoU), last.pth, log.csv.
"""

from __future__ import annotations

import argparse
import csv
import math
import random
import sys
import time
from pathlib import Path

import numpy as np
from PIL import Image, ImageFilter

from common import MEAN, SIZE, STD, is_val, list_images

try:
    import torch
    import torch.nn.functional as F
    from torch.utils.data import DataLoader, Dataset
    from torchvision.transforms import ColorJitter
except ImportError:
    sys.exit("PyTorch + torchvision are required: pip install -r requirements.txt")


# ── Data ────────────────────────────────────────────────────────────────────

def load_ids(data: Path) -> list[str]:
    rejected = set()
    rej = data / "rejected.txt"
    if rej.exists():
        rejected = {l.strip() for l in rej.read_text().splitlines() if l.strip()}
    ids = []
    for img in sorted((data / "images").glob("*.jpg")):
        if img.stem not in rejected and (data / "masks" / f"{img.stem}.png").exists():
            ids.append(img.stem)
    return ids


class StudioDataset(Dataset):
    """Photo + mask pairs with augmentations aimed at the field failures:

    * background swap: the product pasted onto other scenes (tables,
      shelves, screens, clutter), so "interesting surroundings" stop being
      mistaken for product;
    * 90° turns: packs photographed lying down;
    * colour/brightness jitter and blur: shop lighting, shake, cheap cameras;
    * random crops and scale: close-ups of labels and far shots alike.
    """

    def __init__(self, data: Path, ids: list[str], train: bool,
                 backgrounds: list[Path], size: int = SIZE):
        self.data, self.ids, self.train = data, ids, train
        self.backgrounds = backgrounds
        self.size = size
        self.jitter = ColorJitter(0.35, 0.35, 0.35, 0.04)

    def __len__(self) -> int:
        return len(self.ids)

    def _pair(self, sid: str) -> tuple[Image.Image, Image.Image]:
        img = Image.open(self.data / "images" / f"{sid}.jpg").convert("RGB")
        mask = Image.open(self.data / "masks" / f"{sid}.png").convert("L")
        if mask.size != img.size:
            mask = mask.resize(img.size, Image.BILINEAR)
        return img, mask

    def _background(self, size: tuple[int, int]) -> Image.Image | None:
        if self.backgrounds:
            bg = Image.open(random.choice(self.backgrounds)).convert("RGB")
        else:  # another training photo with its product removed works too
            bg, bm = self._pair(random.choice(self.ids))
            if np.asarray(bm).mean() > 0.6 * 255:
                return None  # mostly product; not a useful background
        scale = max(size[0] / bg.width, size[1] / bg.height) * random.uniform(1, 1.6)
        bg = bg.resize((math.ceil(bg.width * scale), math.ceil(bg.height * scale)))
        x = random.randint(0, bg.width - size[0])
        y = random.randint(0, bg.height - size[1])
        return bg.crop((x, y, x + size[0], y + size[1]))

    def __getitem__(self, i: int):
        img, mask = self._pair(self.ids[i])
        if self.train:
            if random.random() < 0.35:
                bg = self._background(img.size)
                if bg is not None:
                    img = Image.composite(img, bg, mask)
            if random.random() < 0.25:
                k = random.choice([Image.ROTATE_90, Image.ROTATE_270])
                img, mask = img.transpose(k), mask.transpose(k)
            if random.random() < 0.5:
                img = img.transpose(Image.FLIP_LEFT_RIGHT)
                mask = mask.transpose(Image.FLIP_LEFT_RIGHT)
            angle = random.uniform(-12, 12)
            img = img.rotate(angle, Image.BILINEAR, fillcolor=(128, 128, 128))
            mask = mask.rotate(angle, Image.BILINEAR, fillcolor=0)
            # Random crop: 55–100% of each side.
            w, h = img.size
            cw, ch = int(w * random.uniform(0.55, 1)), int(h * random.uniform(0.55, 1))
            x, y = random.randint(0, w - cw), random.randint(0, h - ch)
            img, mask = img.crop((x, y, x + cw, y + ch)), mask.crop((x, y, x + cw, y + ch))
            img = self.jitter(img)
            if random.random() < 0.15:
                img = img.filter(ImageFilter.GaussianBlur(random.uniform(0.5, 2.0)))

        img = img.resize((self.size, self.size), Image.BILINEAR)
        mask = mask.resize((self.size, self.size), Image.BILINEAR)
        x = np.asarray(img, np.float32)
        x = x / max(1.0, float(x.max()))  # same as the app: divide by image max
        x = (x - MEAN) / STD
        y = np.asarray(mask, np.float32)[None] / 255.0
        return torch.from_numpy(x.transpose(2, 0, 1).copy()), torch.from_numpy(y)


# ── Training ────────────────────────────────────────────────────────────────

def loss_fn(outputs, target):
    """U²-Net's deep supervision (BCE on all 7 side outputs) plus a soft-IoU
    term on the final map, which punishes kept background (a strip of table,
    a hand) more directly than per-pixel BCE does."""
    target = target.float()
    bce = sum(F.binary_cross_entropy(o.float().clamp(1e-6, 1 - 1e-6), target)
              for o in outputs)
    d0 = outputs[0].float()
    inter = (d0 * target).sum((1, 2, 3))
    union = (d0 + target - d0 * target).sum((1, 2, 3))
    soft_iou = 1 - ((inter + 1) / (union + 1)).mean()
    return bce + soft_iou


@torch.no_grad()
def evaluate(net, loader, device) -> tuple[float, float]:
    net.eval()
    ious, maes = [], []
    for x, y in loader:
        d0 = net(x.to(device))[0].float()
        y = y.to(device)
        p, g = d0 >= 0.5, y >= 0.5
        inter = (p & g).sum((1, 2, 3)).float()
        union = (p | g).sum((1, 2, 3)).float()
        ious += torch.where(union > 0, inter / union.clamp(min=1),
                            torch.ones_like(union)).tolist()
        maes += (d0 - y).abs().mean((1, 2, 3)).tolist()
    net.train()
    return float(np.mean(ious)), float(np.mean(maes))


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawTextHelpFormatter)
    ap.add_argument("--data", required=True, type=Path)
    ap.add_argument("--repo", required=True, type=Path,
                    help="clone of github.com/xuebinqin/U-2-Net (model code)")
    ap.add_argument("--weights", type=Path,
                    help="starting u2netp.pth (omit only for a smoke test)")
    ap.add_argument("--out", default=Path("runs/exp"), type=Path)
    ap.add_argument("--backgrounds", type=Path,
                    help="folder of background photos (shelves, tables, screens)")
    ap.add_argument("--epochs", type=int, default=60)
    ap.add_argument("--batch", type=int, default=12)
    ap.add_argument("--lr", type=float, default=1e-4)
    ap.add_argument("--val-frac", type=float, default=0.15)
    ap.add_argument("--patience", type=int, default=12,
                    help="stop after this many epochs without improvement")
    ap.add_argument("--workers", type=int, default=4)
    ap.add_argument("--max-steps", type=int, default=0,
                    help="stop after N steps (smoke test)")
    ap.add_argument("--seed", type=int, default=0)
    args = ap.parse_args()

    random.seed(args.seed)
    np.random.seed(args.seed)
    torch.manual_seed(args.seed)

    sys.path.insert(0, str(args.repo.resolve()))
    from model import U2NETP  # noqa: E402 (from the U-2-Net repo)

    device = ("cuda" if torch.cuda.is_available()
              else "mps" if torch.backends.mps.is_available() else "cpu")
    ids = load_ids(args.data)
    train_ids = [i for i in ids if not is_val(i, args.val_frac)]
    val_ids = [i for i in ids if is_val(i, args.val_frac)]
    if len(train_ids) < 10 or not val_ids:
        sys.exit(f"too few samples (train {len(train_ids)}, val {len(val_ids)});"
                 " add more photos")
    backgrounds = list_images(args.backgrounds) if args.backgrounds else []
    print(f"device {device} · train {len(train_ids)} · val {len(val_ids)} · "
          f"backgrounds {len(backgrounds) or 'from dataset'}")

    train_dl = DataLoader(
        StudioDataset(args.data, train_ids, True, backgrounds),
        batch_size=args.batch, shuffle=True, num_workers=args.workers,
        drop_last=True, pin_memory=device == "cuda",
        persistent_workers=args.workers > 0)
    val_dl = DataLoader(
        StudioDataset(args.data, val_ids, False, backgrounds),
        batch_size=args.batch, num_workers=args.workers)

    net = U2NETP(3, 1)
    if args.weights:
        net.load_state_dict(torch.load(args.weights, map_location="cpu"))
    else:
        print("WARNING: no --weights: training from scratch (smoke test only)")
    net.to(device).train()

    opt = torch.optim.AdamW(net.parameters(), lr=args.lr, weight_decay=1e-4)
    total = args.epochs * len(train_dl)
    warm = min(300, total // 10)
    sched = torch.optim.lr_scheduler.LambdaLR(
        opt, lambda s: (s + 1) / warm if s < warm
        else 0.5 * (1 + math.cos(math.pi * (s - warm) / max(1, total - warm))))
    scaler = torch.amp.GradScaler("cuda", enabled=device == "cuda")

    args.out.mkdir(parents=True, exist_ok=True)
    log = (args.out / "log.csv").open("w", newline="")
    writer = csv.writer(log)
    writer.writerow(["epoch", "train_loss", "val_iou", "val_mae", "lr", "secs"])

    base_iou, base_mae = evaluate(net, val_dl, device)
    print(f"before training: val IoU {base_iou:.4f}  MAE {base_mae:.4f}")
    writer.writerow([0, "", f"{base_iou:.4f}", f"{base_mae:.4f}", "", 0])
    best, since_best, step = base_iou, 0, 0
    torch.save(net.state_dict(), args.out / "best.pth")

    for epoch in range(1, args.epochs + 1):
        t0, losses = time.time(), []
        for x, y in train_dl:
            x, y = x.to(device, non_blocking=True), y.to(device, non_blocking=True)
            with torch.autocast(device_type="cuda", enabled=device == "cuda"):
                outputs = net(x)
            loss = loss_fn(outputs, y)
            opt.zero_grad(set_to_none=True)
            scaler.scale(loss).backward()
            scaler.step(opt)
            scaler.update()
            sched.step()
            losses.append(loss.item())
            step += 1
            if args.max_steps and step >= args.max_steps:
                break
        val_iou, val_mae = evaluate(net, val_dl, device)
        secs = time.time() - t0
        lr = opt.param_groups[0]["lr"]
        print(f"epoch {epoch:3d}  loss {np.mean(losses):.4f}  val IoU "
              f"{val_iou:.4f}  MAE {val_mae:.4f}  ({secs:.0f}s)")
        writer.writerow([epoch, f"{np.mean(losses):.4f}", f"{val_iou:.4f}",
                         f"{val_mae:.4f}", f"{lr:.2e}", f"{secs:.0f}"])
        log.flush()
        torch.save(net.state_dict(), args.out / "last.pth")
        if val_iou > best:
            best, since_best = val_iou, 0
            torch.save(net.state_dict(), args.out / "best.pth")
            print(f"  ↑ new best, saved {args.out / 'best.pth'}")
        else:
            since_best += 1
            if since_best >= args.patience:
                print("no improvement for a while; stopping early")
                break
        if args.max_steps and step >= args.max_steps:
            break
    log.close()
    print(f"\nBest val IoU {best:.4f} (started at {base_iou:.4f}). "
          f"Next: export best.pth → .tflite and run evaluate.py.")


if __name__ == "__main__":
    main()

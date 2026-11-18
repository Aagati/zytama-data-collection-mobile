"""Shared helpers for the studio-model training kit.

Everything here mirrors what the app does on the phone
(lib/features/product/data/services/studio_image_service.dart), so a model
trained and evaluated with this kit behaves the same once it ships:

* U²-Netp input: photo resized to 320×320, divided by the image's own max
  value, then ImageNet mean/std; NHWC float32 for TFLite.
* Hand model (MediaPipe selfie-multiclass): 256×256 RGB in [0, 1], 6 class
  logits; skin = body-skin + face-skin after softmax.
* Skin that lies entirely inside the product (pink/orange print) is not a
  hand: only skin regions reaching out past the product count.
"""

from __future__ import annotations

import hashlib
from pathlib import Path

import numpy as np
from PIL import Image, ImageOps

SIZE = 320
MEAN = np.array([0.485, 0.456, 0.406], np.float32)
STD = np.array([0.229, 0.224, 0.225], np.float32)
IMAGE_EXTS = {".jpg", ".jpeg", ".png", ".webp", ".bmp"}

REPO_ROOT = Path(__file__).resolve().parents[2]
APP_OBJECT_MODEL = REPO_ROOT / "assets/models/u2netp.tflite"
APP_HAND_MODEL = REPO_ROOT / "assets/models/selfie_multiclass_256x256.tflite"


# ── Images ──────────────────────────────────────────────────────────────────

def load_rgb(path: Path, max_side: int | None = None) -> Image.Image:
    """Opens a photo upright (EXIF rotation applied, as the phone does)."""
    im = ImageOps.exif_transpose(Image.open(path)).convert("RGB")
    if max_side and max(im.size) > max_side:
        im.thumbnail((max_side, max_side), Image.LANCZOS)
    return im


def list_images(folder: Path) -> list[Path]:
    return sorted(
        p for p in folder.rglob("*")
        if p.suffix.lower() in IMAGE_EXTS and not p.name.startswith(".")
    )


def normalize(rgb: np.ndarray) -> np.ndarray:
    """App normalisation of an HxWx3 uint8/float array → float32 HxWx3."""
    x = rgb.astype(np.float32)
    x = x / max(1.0, float(x.max()))
    return (x - MEAN) / STD


def is_val(sample_id: str, val_frac: float) -> bool:
    """Stable train/val split by id hash: the same photo always lands in the
    same split, so scores stay comparable between runs and dataset growth."""
    h = int(hashlib.sha1(sample_id.encode()).hexdigest()[:8], 16)
    return (h % 1000) < val_frac * 1000


# ── TFLite ──────────────────────────────────────────────────────────────────

def tflite_interpreter(path: Path, threads: int = 4):
    try:
        from ai_edge_litert.interpreter import Interpreter
    except ImportError:
        try:
            from tflite_runtime.interpreter import Interpreter
        except ImportError:
            import tensorflow as tf
            Interpreter = tf.lite.Interpreter
    it = Interpreter(model_path=str(path), num_threads=threads)
    it.allocate_tensors()
    return it


def run_saliency(it, img: Image.Image) -> np.ndarray:
    """U²-Netp raw sigmoid map (S×S, 0..1), exactly as the app computes it."""
    inp = it.get_input_details()[0]
    shape = inp["shape"]
    nchw = len(shape) == 4 and shape[1] == 3
    size = int(shape[2] if nchw else shape[1])
    small = np.asarray(img.resize((size, size), Image.BILINEAR))
    x = normalize(small)[None]
    if nchw:
        x = x.transpose(0, 3, 1, 2)
    it.set_tensor(inp["index"], x.astype(np.float32))
    it.invoke()
    out = it.get_tensor(it.get_output_details()[0]["index"])
    return np.asarray(out, np.float32).reshape(size, size)


def run_skin(it, img: Image.Image) -> np.ndarray:
    """P(skin) map from the MediaPipe selfie-multiclass model (H×W)."""
    inp = it.get_input_details()[0]
    h, w = int(inp["shape"][1]), int(inp["shape"][2])
    x = np.asarray(img.resize((w, h), Image.BILINEAR), np.float32) / 255.0
    it.set_tensor(inp["index"], x[None])
    it.invoke()
    logits = it.get_tensor(it.get_output_details()[0]["index"]).reshape(h, w, 6)
    e = np.exp(logits - logits.max(-1, keepdims=True))
    p = e / e.sum(-1, keepdims=True)
    return (p[..., 2] + p[..., 3]).astype(np.float32)


# ── Masks ───────────────────────────────────────────────────────────────────

def resize_map(m: np.ndarray, size: tuple[int, int]) -> np.ndarray:
    """Bilinear resize of a float map to (width, height)."""
    im = Image.fromarray(m.astype(np.float32), mode="F")
    return np.asarray(im.resize(size, Image.BILINEAR), np.float32)


def minmax(m: np.ndarray) -> np.ndarray:
    lo, hi = float(m.min()), float(m.max())
    return (m - lo) / (hi - lo) if hi - lo > 1e-6 else np.zeros_like(m)


def filter_skin_to_hands(skin: np.ndarray, obj: np.ndarray) -> np.ndarray:
    """Keeps only skin regions that reach outside the object (a hand holding
    a pack); skin-like print fully inside the product is zeroed. Same rule
    as filterSkinToHands() in the app."""
    from scipy import ndimage

    obj_s = resize_map(obj, (skin.shape[1], skin.shape[0]))
    labels, n = ndimage.label(skin > 0.4)  # 4-connected, like the app
    if n == 0:
        return np.zeros_like(skin)
    outside = ndimage.sum(obj_s < 0.3, labels, index=np.arange(1, n + 1))
    keep_ids = np.flatnonzero(outside >= 4) + 1
    kept = np.isin(labels, keep_ids)
    near = ndimage.binary_dilation(kept, structure=np.ones((7, 7), bool))
    return np.where(near, skin, 0).astype(np.float32)


def largest_component(mask: np.ndarray, thr: float = 0.5) -> np.ndarray:
    """Zeroes everything but the largest blob (keeps soft edges around it)."""
    from scipy import ndimage

    labels, n = ndimage.label(mask >= thr)
    if n <= 1:
        return mask
    sizes = ndimage.sum(np.ones_like(mask), labels, index=np.arange(1, n + 1))
    keep = labels == (int(np.argmax(sizes)) + 1)
    keep = ndimage.binary_dilation(keep, iterations=3)
    return np.where(keep, mask, 0).astype(np.float32)


def iou(pred: np.ndarray, gt: np.ndarray, thr: float = 0.5) -> float:
    p, g = pred >= thr, gt >= thr
    union = np.logical_or(p, g).sum()
    return 1.0 if union == 0 else float(np.logical_and(p, g).sum() / union)


def boundary_f(pred: np.ndarray, gt: np.ndarray, tol_frac: float = 0.01,
               thr: float = 0.5) -> float:
    """Boundary F-measure: how well the outlines match, within a tolerance of
    ~1% of the image diagonal. IoU barely moves for a ragged edge or a thin
    strip of background; this does."""
    from scipy import ndimage

    p, g = pred >= thr, gt >= thr
    pb = p ^ ndimage.binary_erosion(p)
    gb = g ^ ndimage.binary_erosion(g)
    if not pb.any() and not gb.any():
        return 1.0
    if not pb.any() or not gb.any():
        return 0.0
    tol = max(1, round(tol_frac * float(np.hypot(*p.shape))))
    gd = ndimage.distance_transform_edt(~gb)
    pd = ndimage.distance_transform_edt(~pb)
    precision = float((gd[pb] <= tol).mean())
    recall = float((pd[gb] <= tol).mean())
    return 0.0 if precision + recall == 0 else \
        2 * precision * recall / (precision + recall)


def leak(pred: np.ndarray, gt: np.ndarray, thr: float = 0.5) -> float:
    """Share of the predicted cut-out that isn't product (hand, table,
    screen…): the "extra stuff kept" problem, as a number."""
    p, g = pred >= thr, gt >= thr
    return 0.0 if not p.any() else float((p & ~g).sum() / p.sum())

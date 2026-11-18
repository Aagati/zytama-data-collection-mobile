# Studio model training kit

Trains the app's product cut-out model (**U²-Netp**, `assets/models/u2netp.tflite`)
on our own field photos. The goal is to fix the problems we've been patching
in code at the source: hands left on the pack, attached surroundings (table,
shelf, screen) kept, pink and orange packs half-erased, and labels with their
white areas cut.

The model's size, input and output stay exactly the same. A trained model is a
drop-in file swap: **no app code changes**.

```
photos ─► prepare_dataset.py ─► review & fix masks ─► train.py ─► export ─► evaluate.py ─► ship
          (draft masks by a      (you: ~1–2 s per     (GPU,       (.tflite)  (old vs new on
           big teacher model)     photo, fix ~10–20%)  1–3 h)                 unseen photos)
```

## What you need

- **Photos**: 300 minimum, about 1,000 for a solid model. Use real field captures:
  front of packs, ingredients and nutrition labels, packs held in hand, on
  tables, on shelves, lying flat. Variety matters more than count.
- **A GPU for training**: free Google Colab (T4) is enough. Everything else runs
  on a laptop.
- Python 3.10–3.12: `pip install -r requirements.txt`

## 1. Collect photos

From a phone running a **debug** build of the app (USB debugging on):

```bash
./pull_photos_from_phone.sh phone_photos
```

Or put photos from anywhere (the backend's uploaded originals are best) into
one folder. Only use **original** photos, never the app's `studio_*` outputs.

## 2. Make draft masks

```bash
python prepare_dataset.py --input phone_photos --out dataset
```

A large, accurate "teacher" model (`isnet-general-use`, downloaded on first
run) draws a mask for each photo. Hands are then removed with the same hand
model and rules the app uses. The command can be re-run as more photos come
in: photos already done are skipped.

## 3. Review the drafts (the important part)

Open `dataset/review.html`. It shows each photo next to its cut-out, with the
**most doubtful first**.

- **Good**: do nothing.
- **Small mistake** (a bit of hand kept, an edge missing): open
  `dataset/masks/<id>.png` in any image editor (Photopea in the browser, GIMP,
  Photoshop) and paint **white = product**, **black = everything else**. Save
  it as PNG with the same name.
- **Bad or useless photo** (no product, very blurry, several products): add its
  id to `dataset/rejected.txt`, one per line.

Rules that keep the model consistent:
- The **product only**: never a hand, finger, table, shelf, screen or price tag.
- For labels, include the **whole label/pack area**, white parts too.
- If a finger covers part of the pack, mark the finger black; don't guess
  what's under it.

Expect to fix roughly 10–20% of drafts. The mask quality directly sets the
model's quality.

## 4. Train (Colab)

Open `train_colab.ipynb` in Google Colab and follow its first cell. It covers
uploading to Drive, training, exporting and evaluating. Or on any GPU machine:

```bash
git clone https://github.com/xuebinqin/U-2-Net.git
python train.py --data dataset --repo U-2-Net --weights u2netp.pth --out runs/exp1 \
    [--backgrounds backgrounds/]
```

`--backgrounds` is optional but helps: 50–200 photos of empty shelves,
counters, tables, laptop screens, i.e. places products sit, **without** a
product. Training pastes products onto them so the model learns that
"interesting surroundings" aren't the product.

Training keeps the epoch with the best validation score (`best.pth`) and stops
by itself when it stops improving.

## 5. Export and evaluate

```bash
python ../../scripts/convert_u2netp_to_tflite.py --repo U-2-Net \
    --weights runs/exp1/best.pth --out runs/exp1/u2netp_finetuned.tflite
python evaluate.py --data dataset --old ../../assets/models/u2netp.tflite \
    --new runs/exp1/u2netp_finetuned.tflite --out runs/exp1/eval
```

The evaluation runs both models exactly as the phone does on validation
photos that training never saw, and reports:

| Score | Meaning | Better |
|---|---|---|
| IoU | overall overlap with the true product | higher |
| boundary F | how well the outline follows the product edge | higher |
| leak | share of the cut-out that isn't product (hand, table, strips) | lower |

It ends with a **SHIP / DON'T SHIP** verdict and saves side-by-side images of
the photos where the two models differ most.

## 6. Ship

Only when the verdict says **SHIP**: replace `assets/models/u2netp.tflite` with
the new file and rebuild the app. Keep the old file to roll back. Re-run steps
1–5 every few weeks as new products come in; the dataset keeps growing.

## Files

| File | Purpose |
|---|---|
| `pull_photos_from_phone.sh` | copy original captures off a debug phone |
| `prepare_dataset.py` | draft masks + hand removal + review page |
| `train.py` | fine-tune U²-Netp with field-specific augmentations |
| `evaluate.py` | old vs new model on unseen photos, ship verdict |
| `common.py` | preprocessing and metrics identical to the app |
| `train_colab.ipynb` | the whole flow on free Colab GPU |
| `../../scripts/convert_u2netp_to_tflite.py` | PyTorch → `.tflite` (`--out` for new models) |

Photos, datasets and runs are git-ignored: they contain product images and are
large. Keep them on Drive or a shared disk, not in the repo.

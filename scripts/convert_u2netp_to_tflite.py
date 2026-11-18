"""Convert U²-Netp (PyTorch) to the TFLite model the app uses for studio photos.

U²-Netp is the 4.7 MB "lite" U²-Net salient-object model by Xuebin Qin et al.,
Apache-2.0: https://github.com/xuebinqin/U-2-Net

Output: assets/models/u2netp.tflite — float32, NHWC input [1, 320, 320, 3],
single output [1, 320, 320, 1] = the fused saliency map (d0), ≈4.4 MB.
(onnx2tf's *_float16 file uses float16 inputs/activations, which the
TFLite CONV_2D kernel rejects, so the float32 file is the one we ship.)
Verified 2026-11-17: max |tflite − pytorch| = 0.0002 on the repo's test images.
StudioImageService reads the input shape at runtime, so NCHW also works.

One-time setup (any machine with Python 3.10–3.12; nothing runs on the phone):

    git clone https://github.com/xuebinqin/U-2-Net.git /tmp/U-2-Net
    # Download u2netp.pth via the link in that repo's README and put it at
    #   /tmp/U-2-Net/saved_models/u2netp/u2netp.pth
    python3 -m venv /tmp/u2venv && source /tmp/u2venv/bin/activate
    pip install torch onnx onnxsim onnx2tf tensorflow tf_keras \
        onnx_graphsurgeon sng4onnx psutil ai_edge_litert
    python3 scripts/convert_u2netp_to_tflite.py --repo /tmp/U-2-Net

Then commit assets/models/u2netp.tflite.

Fine-tuned weights (ml/studio_model/train.py) convert the same way:
    python3 scripts/convert_u2netp_to_tflite.py --repo /tmp/U-2-Net \
        --weights runs/exp1/best.pth --out runs/exp1/u2netp_finetuned.tflite
Weights used: u2netp.pth, sha256 e7567cde013fb64813973ce6e1ecc25a80c05c3ca7adbc5a54f3c3d90991b854
"""

import argparse
import shutil
import subprocess
import sys
from pathlib import Path


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--repo", required=True, help="path to a U-2-Net clone")
    ap.add_argument(
        "--weights",
        help="u2netp.pth (default: <repo>/saved_models/u2netp/u2netp.pth)",
    )
    ap.add_argument("--size", type=int, default=320, help="input resolution")
    ap.add_argument("--work", default="/tmp/u2netp_tflite", help="scratch dir")
    ap.add_argument(
        "--out",
        help="where to write the .tflite (default: assets/models/u2netp.tflite;"
        " pass a path for a fine-tuned model so it can be evaluated first)",
    )
    args = ap.parse_args()

    repo = Path(args.repo).resolve()
    weights = Path(args.weights or repo / "saved_models/u2netp/u2netp.pth")
    if not weights.exists():
        sys.exit(f"weights not found: {weights}")
    sys.path.insert(0, str(repo))

    import torch
    from model import U2NETP  # from the U-2-Net repo

    class FusedOnly(torch.nn.Module):
        """U²-Net returns 7 side outputs; the app only needs the fused d0.
        Exporting just that keeps output index 0 unambiguous after conversion."""

        def __init__(self, net: torch.nn.Module) -> None:
            super().__init__()
            self.net = net

        def forward(self, x):  # already sigmoid-activated in U2NETP.forward
            return self.net(x)[0]

    net = U2NETP(3, 1)
    net.load_state_dict(torch.load(weights, map_location="cpu"))
    net.eval()

    work = Path(args.work)
    work.mkdir(parents=True, exist_ok=True)
    onnx_path = work / "u2netp.onnx"
    dummy = torch.randn(1, 3, args.size, args.size)
    torch.onnx.export(
        FusedOnly(net), dummy, onnx_path,
        input_names=["input"], output_names=["mask"], opset_version=17,
    )
    print(f"ONNX written: {onnx_path}")

    out_dir = work / "tflite"
    # onnx2tf converts NCHW → NHWC and writes *_float32 and *_float16 models.
    subprocess.run(
        ["onnx2tf", "-i", str(onnx_path), "-o", str(out_dir), "-osd"],
        check=True,
    )
    src = out_dir / "u2netp_float32.tflite"
    if not src.exists():
        sys.exit(f"expected {src}; check the onnx2tf output above")

    dest = Path(args.out) if args.out else (
        Path(__file__).resolve().parents[1] / "assets/models/u2netp.tflite")
    dest.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy(src, dest)
    print(f"Copied to {dest} ({dest.stat().st_size / 1e6:.1f} MB)")


if __name__ == "__main__":
    main()

#!/usr/bin/env bash
# Copies the original capture photos off a phone running a debug build of
# the app (USB debugging on), for use as training data.
#
#   ./pull_photos_from_phone.sh [out_dir]      (default: phone_photos/)
#
# Takes the camera originals (cache) and the offline-upload copies, and skips
# the app's own studio outputs (studio_*.jpg): the model must learn from the
# real photos, not from its own earlier cut-outs. Run it after each field
# session; prepare_dataset.py skips photos it has already added.
set -euo pipefail

PKG=com.zytama.datacollection
OUT=${1:-phone_photos}
ADB=${ADB:-adb}
if ! command -v "$ADB" >/dev/null; then
  ADB="$HOME/Library/Android/sdk/platform-tools/adb"
fi

"$ADB" get-state >/dev/null 2>&1 || { echo "No phone found: connect it with USB debugging on."; exit 1; }
mkdir -p "$OUT"

# run-as works for debug builds only (release builds keep their files private).
files=$("$ADB" shell run-as "$PKG" find cache app_flutter -type f \
  \( -iname '*.jpg' -o -iname '*.jpeg' \) 2>/dev/null | tr -d '\r' | grep -v '/studio_' || true)
if [ -z "$files" ]; then
  echo "No photos found (is a debug build of the app installed and used?)"
  exit 1
fi

n=0
while IFS= read -r f; do
  name=$(echo "$f" | tr '/' '_')
  [ -s "$OUT/$name" ] && continue
  "$ADB" exec-out run-as "$PKG" cat "$f" > "$OUT/$name"
  n=$((n + 1))
done <<< "$files"
echo "Copied $n new photos to $OUT/ ($(ls "$OUT" | wc -l | tr -d ' ') total)."

#!/bin/bash
# refresh-model-cache.sh — re-parse test fixtures and pre-warm the app's
# disk cache with the current parser output.
#
# Use cases:
#   - After changing the parser/tessellation code: refresh every cached
#     entry so opening a file in the app shows the new geometry.
#   - Verify a re-parse run end-to-end (parse → serialize → cache file).
#
# Usage:
#   bash macos/scripts/refresh-model-cache.sh                # all testfile STEP files
#   MMFORGE_BENCH_FILES="方盒子.step;躺板板.STEP" \
#     bash macos/scripts/refresh-model-cache.sh              # specific files
#
# The cache key is computed exactly like the app's ModelCache.cacheKey
# (path|size|mtime|extension|parser-version|occt-tag + SHA256 content
# sample), with the parser version read from the Rust core so keys stay in
# sync with what the app computes.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
APP_CACHE="${MMFORGE_CACHE_DIR:-$HOME/Library/Application Support/MMForge/ModelCache}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

FILES="${MMFORGE_BENCH_FILES:-}"
if [ -z "$FILES" ]; then
  # while-read preserves spaces in filenames (xargs would split them).
  FILES="$(ls "$ROOT"/testfile/*.step "$ROOT"/testfile/*.stp "$ROOT"/testfile/*.STEP \
           2>/dev/null | while read -r f; do basename "$f"; done | paste -sd ';' -)"
fi
if [ -z "$FILES" ]; then
  echo "no files found — set MMFORGE_BENCH_FILES (relative to testfile/)" >&2
  exit 1
fi

echo "== Re-parsing: $FILES"
echo "== Cache dir: $APP_CACHE"
mkdir -p "$APP_CACHE" "$WORK/out"

# Re-parse + serialize each file (Rust side, with OCCT).
MMFORGE_CACHE_OUT="$WORK/out" \
MMFORGE_BENCH_FILES="$FILES" \
MMFORGE_TESTFILES="$ROOT/testfile" \
OCCT_INCLUDE_DIR="${OCCT_INCLUDE_DIR:-/opt/homebrew/include/opencascade}" \
OCCT_LIB_DIR="${OCCT_LIB_DIR:-/opt/homebrew/lib}" \
cargo test --release -p mmforge-bridge --test cache_bench --features occt \
  -- --ignored --nocapture 2>/dev/null | grep -E "\.step|\.stp|\.STEP" || true

if [ ! -f "$WORK/out/.cache_version" ]; then
  echo "ERROR: cache_bench produced no output — parse failed?" >&2
  exit 1
fi

# Compute app-equivalent cache keys and install the entries.
python3 - "$ROOT/testfile" "$WORK/out" "$APP_CACHE" "$FILES" <<'PY'
import hashlib
import os
import sys

root, out_dir, cache_dir, files_csv = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
parser_version = open(os.path.join(out_dir, ".cache_version")).read().strip()
files = [f for f in files_csv.split(";") if f]

def cache_key(path: str) -> str:
    st = os.stat(path)
    size = st.st_size
    # Swift: Int(mtime.timeIntervalSince1970) — truncation toward zero.
    mtime = int(st.st_mtime)
    with open(path, "rb") as f:
        head = f.read(4096)
        tail = b""
        if size > 8192:
            f.seek(size - 4096)
            tail = f.read(4096)
    ext = os.path.splitext(path)[1].lstrip(".")  # preserves case, like URL.pathExtension
    base = f"{path}|{size}|{mtime}|{ext}|{parser_version}|no-occt"
    h = hashlib.sha256(head + tail).hexdigest()
    return hashlib.sha256((base + "|" + h).encode()).hexdigest()

installed = 0
for name in files:
    src = os.path.join(out_dir, name.replace("/", "_").replace(" ", "_") + ".lsm")
    if not os.path.exists(src):
        print(f"  skip {name}: no serialized output")
        continue
    path = os.path.join(root, name)
    key = cache_key(path)
    dst = os.path.join(cache_dir, key + ".lsmc")
    os.replace(src, dst)
    print(f"  {name}: {os.path.getsize(dst)/1e6:.1f} MB -> {key[:12]}…")
    installed += 1

print(f"== Installed {installed} cache entr{'y' if installed == 1 else 'ies'} "
      f"(parser version {parser_version})")
PY

#!/usr/bin/env bash
# Extracts the runtime-compiled Metal source from MetalShaders.swift and compiles
# it with Apple's offline compiler, so shader typos fail the build instead of
# silently disabling the 3D visualisers at runtime.
set -euo pipefail
cd "$(dirname "$0")/.."
OUT="${TMPDIR:-/tmp}/encore-shaders"
mkdir -p "$OUT"
python3 - "$OUT/Shaders.metal" <<'PY'
import re, sys
src = open("Sources/Encore/UI/Visualizers/MetalShaders.swift").read()
m = re.search(r'#"""\n(.*?)\n"""#', src, re.S)
if not m:
    sys.exit("Metal source not found")
open(sys.argv[1], "w").write(m.group(1))
PY
if ! xcrun -sdk macosx -f metal >/dev/null 2>&1; then
  echo "warning: Metal compiler not installed (xcodebuild -downloadComponent MetalToolchain); skipping shader check"
  exit 0
fi
if ! xcrun -sdk macosx metal -c "$OUT/Shaders.metal" -o "$OUT/Shaders.air" 2>"$OUT/log.txt"; then
  if grep -q "cannot execute tool 'metal' due to missing Metal Toolchain" "$OUT/log.txt"; then
    echo "warning: Metal Toolchain component missing; skipping shader check"
    exit 0
  fi
  cat "$OUT/log.txt"
  exit 1
fi
cat "$OUT/log.txt"
echo "Metal shaders compile cleanly."

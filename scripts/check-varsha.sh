#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/build-varsha"; mkdir -p "$OUT"
xcrun swiftc -swift-version 5 -parse-as-library -O -framework Metal -framework QuartzCore \
    "$ROOT/Varsha/RainEngine.swift" "$ROOT/Varsha/WindowWater.swift" "$ROOT/Varsha/RainStreaks.swift" \
    "$ROOT/tests/RainChecks.swift" -o "$OUT/rain-checks"
"$OUT/rain-checks" "$ROOT/Varsha/Fluid.metal" "$ROOT/Varsha/Rain.metal"

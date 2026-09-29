#!/bin/bash
# Writes the SRI hash of a release DMG into nix/default.nix.
#
# Usage: scripts/pin-nix-hash.sh <Roopam-X.Y.Z.dmg.sha256>
#   "13437f...58e  Roopam-1.3.0.dmg" -> hash = "sha256-E0N/Y2z2YOx2...";
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CHECKSUM="${1:?usage: pin-nix-hash.sh <dmg.sha256>}"
HEX=$(cut -d' ' -f1 "$CHECKSUM")
[[ "$HEX" =~ ^[0-9a-f]{64}$ ]] || { echo "error: $CHECKSUM does not hold a SHA-256 hex digest" >&2; exit 1; }
SRI="sha256-$(echo "$HEX" | xxd -r -p | base64)"
sed -i '' -E "/Set after the first Roopam release/d; s|^    hash = .*;|    hash = \"$SRI\";|" "$ROOT/nix/default.nix"
echo "nix/default.nix hash = $SRI"

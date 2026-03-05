#!/bin/bash
# Re-sign native libraries to prevent macOS code signature crashes
# Run after :TSUpdate, :TSInstall, :Lazy update, or nvim upgrades

set -euo pipefail

PARSER_DIR="$HOME/.local/share/nvim/site/parser"
BLINK_LIB="$HOME/.local/share/nvim/lazy/blink.cmp/target/release/libblink_cmp_fuzzy.dylib"

sign_dir() {
  local dir="$1"
  local pattern="$2"
  if compgen -G "$dir"/$pattern > /dev/null 2>&1; then
    xattr -cr "$dir"
    codesign -fs - "$dir"/$pattern
    echo "Signed $(ls "$dir"/$pattern | wc -l | tr -d ' ') files in $dir"
  fi
}

# Treesitter parsers
if [ -d "$PARSER_DIR" ]; then
  sign_dir "$PARSER_DIR" "*.so"
fi

# Blink.cmp fuzzy lib — pre-built GitHub release binaries don't have com.apple.provenance,
# so codesign -fs - is NOT needed (and would change the checksum, breaking blink.cmp's verification).
# Only strip provenance in case the lib was locally compiled.
if [ -f "$BLINK_LIB" ]; then
  xattr -dr com.apple.provenance "$(dirname "$BLINK_LIB")" 2>/dev/null || true
  echo "Cleared provenance from blink.cmp fuzzy lib (no re-sign — preserves checksum)"
fi

echo "Done."

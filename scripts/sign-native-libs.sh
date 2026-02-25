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

# Blink.cmp fuzzy lib
if [ -f "$BLINK_LIB" ]; then
  xattr -cr "$(dirname "$BLINK_LIB")"
  codesign -fs - "$BLINK_LIB"
  echo "Signed blink.cmp fuzzy lib"
fi

echo "Done."

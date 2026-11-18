#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

./build.sh

DEST=/Applications/Insomniac.app

# Quit any running instance (its quit handler restores normal sleep).
if pgrep -xq Insomniac; then
  osascript -e 'quit app "Insomniac"' 2>/dev/null || pkill -x Insomniac || true
  for _ in {1..20}; do pgrep -xq Insomniac || break; sleep 0.25; done
  pkill -9 -x Insomniac 2>/dev/null || true
fi

rm -rf "$DEST"
ditto build/Insomniac.app "$DEST"
open "$DEST"
echo "Installed to $DEST and launched."

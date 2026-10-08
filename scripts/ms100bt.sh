#!/bin/zsh
# Runs the engine from a terminal through its app wrapper, so macOS grants Bluetooth access.
# Example: scripts/ms100bt.sh state
cd "$(dirname "$0")/.."
[[ -d build/ms100bt-cli.app ]] || scripts/build-app.sh >/dev/null
OUT=$(mktemp); ERR=$(mktemp)
open -W --stdout "$OUT" --stderr "$ERR" build/ms100bt-cli.app --args "$@"
cat "$OUT"; cat "$ERR" >&2
rm -f "$OUT" "$ERR"

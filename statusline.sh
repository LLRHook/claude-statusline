#!/usr/bin/env bash
# Compatibility entry point. Compile/install once; never build on a refresh.
set -euo pipefail

case ${BASH_SOURCE[0]} in
  */*) SCRIPT_DIR=${BASH_SOURCE[0]%/*} ;;
  *) SCRIPT_DIR=. ;;
esac
BINARY=${STATUSLINE_BIN:-"$SCRIPT_DIR/claude-statusline"}
if [ ! -f "$BINARY" ] || [ ! -x "$BINARY" ]; then
  printf '◆ statusline: Rust binary is required\n'
  exit 0
fi
exec "$BINARY" "$@"

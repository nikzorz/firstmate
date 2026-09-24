#!/usr/bin/env bash
# Tracked shell entrypoint for local and fm-on extension binding commands.
set -eu

# Answered before any state, lock, or argument is touched: reading the header
# resolves nothing and writes nothing. Skipped when sourced, where $1 belongs
# to the caller.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  case "${1:-}" in
    -h|--help) awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"; exit 0 ;;
  esac
fi
set -o pipefail

SCRIPT_DIR=$(CDPATH='' cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
if [ "${1:-}" = remote-bind ]; then
  [ "$#" -ge 4 ] || { printf 'usage: %s remote-bind <secondmate-id> <package-root> <bind-options...>\n' "$0" >&2; exit 2; }
  route=$2
  package_root=$3
  shift 3
  "$SCRIPT_DIR/fm-extension.mjs" pack-transfer "$package_root" \
    | "$SCRIPT_DIR/fm-on.sh" --stdin "$route" fm-extension.sh receive-transfer-bind "$@"
  exit $?
fi
exec "$SCRIPT_DIR/fm-extension.mjs" "$@"

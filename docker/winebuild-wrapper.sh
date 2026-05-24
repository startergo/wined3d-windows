#!/bin/bash
SELFDIR="$(cd "$(dirname "$0")" && pwd)"
# Only add --kill-at when generating PE binaries (not .def files for import libs)
# --def means generating a .def file for import lib creation - skip --kill-at there
case "$*" in
  *--def*|*--builtin*) exec "$SELFDIR/winebuild.real" "$@" ;;
  *)                   exec "$SELFDIR/winebuild.real" --kill-at "$@" ;;
esac

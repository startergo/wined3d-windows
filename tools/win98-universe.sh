#!/bin/bash
# win98-universe.sh — regenerate tools/win98-runtime-universe.txt (+ .manifest)
# from a Win98 disk image or an already-extracted WINDOWS directory.
# Methodology: tools/WIN98-UNIVERSE.md. Engine: tools/win98-universe.py.
#
# Usage:
#   tools/win98-universe.sh <disk.qcow2|disk.img|disk.vhd|WINDOWS-dir> [--exclude NAME ...]
#
# Disk images are read with 7-Zip (7z/7zz), which opens qcow2/vhd/vmdk/raw
# directly and walks MBR -> FAT32 itself: no qemu-img convert, no mounting,
# and the image is opened read-only (safe even while you keep the VM around;
# shut the VM down first so the FAT is consistent).
#
# Scanned: WINDOWS\SYSTEM first, then WINDOWS (first occurrence of a module
# name wins — the same order the 9x loader searches for system DLLs).
set -euo pipefail
TOOLS="$(cd "$(dirname "$0")" && pwd)"
SRC="${1:?usage: $0 <disk image | WINDOWS dir> [--exclude NAME ...]}"; shift
OUT="$TOOLS/win98-runtime-universe.txt"
MANIFEST="$TOOLS/win98-runtime-universe.manifest"
PY="$(command -v python3)"

if [ -d "$SRC" ]; then
    WIN="$SRC"
else
    SEVENZ="$(command -v 7zz || command -v 7z || true)"
    [ -n "$SEVENZ" ] || { echo "need 7-Zip (brew install sevenzip)" >&2; exit 1; }
    TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
    echo "[win98-universe] extracting system modules from $SRC ..."
    ( cd "$TMP" && "$SEVENZ" x -y -r- "$SRC" \
        'WINDOWS/SYSTEM/*.DLL' 'WINDOWS/SYSTEM/*.dll' 'WINDOWS/SYSTEM/*.DRV' 'WINDOWS/SYSTEM/*.drv' \
        'WINDOWS/SYSTEM/*.OCX' 'WINDOWS/SYSTEM/*.ocx' 'WINDOWS/SYSTEM/*.ACM' 'WINDOWS/SYSTEM/*.acm' \
        'WINDOWS/SYSTEM/*.CPL' 'WINDOWS/SYSTEM/*.cpl' 'WINDOWS/SYSTEM/*.AX'  'WINDOWS/SYSTEM/*.ax' \
        'WINDOWS/*.DLL' 'WINDOWS/*.dll' >/dev/null )
    WIN="$TMP/WINDOWS"
    [ -f "$WIN/SYSTEM/KERNEL32.DLL" ] || { echo "no WINDOWS/SYSTEM/KERNEL32.DLL in image" >&2; exit 1; }
fi

SYS="$WIN/SYSTEM"; [ -d "$SYS" ] || SYS="$WIN/system"
"$PY" "$TOOLS/win98-universe.py" universe "$SYS" "$WIN" \
    -o "$OUT" --manifest "$MANIFEST" "$@"
grep -E '^(KERNEL32|USER32|GDI32)\.DLL ' "$MANIFEST" | awk '{print "[win98-universe] " $1 " " $2}'

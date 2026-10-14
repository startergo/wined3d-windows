#!/bin/bash
# tests/emu/extract-reference.sh — extract the qemu-3dfx reference Wine DLLs
# (wined3d/d3d8/d3d9/ddraw per Wine version) into tests/emu/reference/<wine-version>/.
#
#   tests/emu/extract-reference.sh /path/to/bundle.tar.zst
#   tests/emu/extract-reference.sh /path/to/image.iso
#
# The source is the qemu-3dfx add-ons bundle (a .tar.zst holding an ISO) or
# the ISO itself; it must contain win32/wine/<wine-version>/.  Override the
# destination the tests read with QEMU3DFX_REF=<dir>.  These are third-party
# binaries; they are .gitignored and extracted locally.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="${1:?usage: $0 <bundle.tar.zst | image.iso>}"
SEVENZ="$(command -v 7zz || command -v 7z || true)"
[ -n "$SEVENZ" ] || { echo "need 7-Zip (brew install sevenzip / apt install 7zip)" >&2; exit 1; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
ISO="$SRC"
case "$SRC" in
    *.tar.zst|*.tzst)
        if command -v zstd >/dev/null; then zstd -dc "$SRC" | tar -C "$TMP" -xf -
        else "$SEVENZ" x -so "$SRC" | tar -C "$TMP" -xf -; fi
        ISO="$(find "$TMP" -iname '*.iso' | head -1)"
        [ -n "$ISO" ] || { echo "no .iso inside $SRC" >&2; exit 1; } ;;
esac

"$SEVENZ" x -y -o"$TMP/iso" "$ISO" 'win32/wine/*' -r >/dev/null
[ -d "$TMP/iso/win32/wine" ] || { echo "no win32/wine in $ISO" >&2; exit 1; }

DEST="${QEMU3DFX_REF:-$HERE/reference}"
mkdir -p "$DEST"
cp -R "$TMP/iso/win32/wine/." "$DEST/"
echo "reference DLLs -> $DEST:"
ls "$DEST"

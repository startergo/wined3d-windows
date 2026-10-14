#!/bin/bash
# tests/emu/run.sh [module|ddraw|d3dkmt|all] — build the test DLLs and run the
# differential emulator tests against the qemu-3dfx reference DLLs.
# Exit status is non-zero if any check fails.  See tests/emu/README.md.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
WHAT="${1:-all}"

# Use $PYTHON if given, else the first python3 that has Unicorn (a venv's
# python3 may shadow the one unicorn was installed into).
if [ -n "${PYTHON:-}" ]; then
    PY="$PYTHON"
else
    PY=""
    for cand in python3 /usr/bin/python3 /usr/local/bin/python3 /opt/homebrew/bin/python3 \
                python3.13 python3.12 python3.11 python3.10 python3.9; do
        if command -v "$cand" >/dev/null 2>&1 && "$cand" -c 'import unicorn' 2>/dev/null; then
            PY="$cand"; break
        fi
    done
    PY="${PY:-python3}"
fi

"$PY" -c 'import unicorn' 2>/dev/null || {
    echo "missing Python package 'unicorn': $PY -m pip install --user unicorn" >&2
    echo "(or point PYTHON= at an interpreter that has it)" >&2; exit 2; }
REF="${QEMU3DFX_REF:-$HERE/reference}"
[ -f "$REF/8.0.2/wined3d.dll" ] || {
    echo "reference DLLs not found in $REF" >&2
    echo "run: tests/emu/extract-reference.sh <bundle.tar.zst | image.iso>" >&2
    exit 2; }

bash "$HERE/build.sh" || exit 1

rc=0
if [ "$WHAT" = all ] || [ "$WHAT" = module ]; then
    echo "### qemu-3dfx module (qemu3dfx_hooks.c)"
    "$PY" "$HERE/test_module.py" || rc=1
fi
if [ "$WHAT" = all ] || [ "$WHAT" = ddraw ]; then
    echo "### ddraw forwarders (qemu3dfx_ddraw_hooks.c)"
    "$PY" "$HERE/test_ddraw.py" || rc=1
fi
if [ "$WHAT" = all ] || [ "$WHAT" = d3dkmt ]; then
    echo "### D3DKMT (docker/d3dkmt_stubs.c)"
    "$PY" "$HERE/test_d3dkmt.py" || rc=1
fi
[ $rc -eq 0 ] && echo "### all emulator tests passed" || echo "### emulator tests FAILED"
exit $rc

#!/bin/bash
# build-verify.sh <wine-version> — build one Wine version into output-verify/<ver>
# without touching output/, applying the same post-build steps as
# build-docker.sh, then run the Win98 checks against the reference DLLs.
set -uo pipefail
cd "$(dirname "$0")/.."
V="${1:?usage: $0 <wine-version>}"
LINE=$(grep -o "\"$V:[^\"]*\"" build-docker.sh | tr -d '"')
[ -n "$LINE" ] || { echo "unknown version $V"; exit 1; }
IFS=: read WINE_VERSION WINE_BRANCH WINE_EXT BUILD_MSVCRT BUILD_MODE <<< "$LINE"
OUT="output-verify/$WINE_VERSION"
LOG="output-verify/build-$WINE_VERSION.log"
mkdir -p "$OUT"
echo "=== $(date) building $WINE_VERSION ($BUILD_MODE) ===" | tee "$LOG"
docker build --platform linux/amd64 --progress=plain \
    --build-arg WINE_VERSION=$WINE_VERSION --build-arg WINE_BRANCH=$WINE_BRANCH \
    --build-arg WINE_EXT=$WINE_EXT --build-arg BUILD_MSVCRT=$BUILD_MSVCRT \
    --build-arg BUILD_MODE=$BUILD_MODE \
    -t wine-dll-builder:$WINE_VERSION . >> "$LOG" 2>&1
rc=$?
echo "=== docker build rc=$rc $(date) ===" | tee -a "$LOG"
[ $rc -eq 0 ] || exit $rc
docker rm -f extract-verify-$WINE_VERSION >/dev/null 2>&1
docker create --name extract-verify-$WINE_VERSION wine-dll-builder:$WINE_VERSION >/dev/null
docker cp extract-verify-$WINE_VERSION:/output/$WINE_VERSION/. "$OUT/" >> "$LOG" 2>&1
docker rm extract-verify-$WINE_VERSION >/dev/null
python3 - "$OUT" <<'EOF'
import sys, os, glob
for p in glob.glob(os.path.join(sys.argv[1], '*.dll')):
    d = open(p, 'rb').read(); r = d.replace(b'ucrtbase.dll\x00', b'msvcrt.dll\x00\x00\x00')
    if r != d: open(p, 'wb').write(r)
EOF
python3 docker/patch_pe_win98.py "$OUT" >> "$LOG" 2>&1
echo "=== DONE $(date): $(ls $OUT) ===" | tee -a "$LOG"

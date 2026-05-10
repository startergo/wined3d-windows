#!/bin/bash
set -e
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
OUTPUT_BASE="$SCRIPT_DIR/output"

# version:branch:ext:msvcrt:mode
VERSIONS=(
    "1.8.7:1.8:tar.bz2:0:legacy"
    "1.9.7:1.9:tar.bz2:0:legacy"
    "2.0.5:2.0:tar.xz:0:legacy"
    "3.0.5:3.0:tar.xz:0:legacy"
    "4.12.1:4.x:tar.xz:0:legacy"
    "5.0.5:5.0:tar.xz:0:legacy"
    "6.0.4:6.0:tar.xz:1:legacy"
    "7.0.2:7.0:tar.xz:0:legacy"
    "8.0.2:8.0:tar.xz:0:modern"
)

FORCE=0
NO_CACHE=""
FILTER_VERSIONS=()
for arg in "$@"; do
    [ "$arg" = "--force" ] && FORCE=1
    [ "$arg" = "--no-cache" ] && NO_CACHE="--no-cache"
    if [ "$_prev" = "--versions" ]; then
        FILTER_VERSIONS+=("$arg")
    fi
    _prev="$arg"
done

fix_ucrtbase_imports() {
    python3 -c "
import sys, os, glob
for path in glob.glob(os.path.join(sys.argv[1], '*.dll')):
    with open(path, 'rb') as f: data = f.read()
    p = data.replace(b'ucrtbase.dll\x00', b'msvcrt.dll\x00\x00\x00')
    if p != data:
        with open(path, 'wb') as f: f.write(p)
        print('  [fix] ucrtbase->msvcrt:', os.path.basename(path))
" "$1"
}

for entry in "${VERSIONS[@]}"; do
    IFS=: read WINE_VERSION WINE_BRANCH WINE_EXT BUILD_MSVCRT BUILD_MODE <<< "$entry"

    if [ ${#FILTER_VERSIONS[@]} -gt 0 ]; then
        skip=1
        for fv in "${FILTER_VERSIONS[@]}"; do
            [ "$fv" = "$WINE_VERSION" ] && skip=0
        done
        [ "$skip" = 1 ] && continue
    fi

    if [ "$FORCE" = "0" ] && [ -f "$OUTPUT_BASE/$WINE_VERSION/wined3d.dll" ]; then
        echo "=== Skipping Wine $WINE_VERSION (already built — use --force to rebuild) ==="
        continue
    fi

    echo "=== Building Wine $WINE_VERSION ($BUILD_MODE) ==="
    docker build $NO_CACHE --platform linux/amd64 \
        --build-arg WINE_VERSION=$WINE_VERSION \
        --build-arg WINE_BRANCH=$WINE_BRANCH \
        --build-arg WINE_EXT=$WINE_EXT \
        --build-arg BUILD_MSVCRT=$BUILD_MSVCRT \
        --build-arg BUILD_MODE=$BUILD_MODE \
        -t wine-dll-builder:$WINE_VERSION \
        "$SCRIPT_DIR"
    mkdir -p "$OUTPUT_BASE/$WINE_VERSION"
    docker create --name extract-$WINE_VERSION wine-dll-builder:$WINE_VERSION
    docker cp extract-$WINE_VERSION:/output/$WINE_VERSION/. "$OUTPUT_BASE/$WINE_VERSION/"
    docker rm extract-$WINE_VERSION
    echo "Done: $(ls "$OUTPUT_BASE/$WINE_VERSION/")"
    fix_ucrtbase_imports "$OUTPUT_BASE/$WINE_VERSION"
done

echo ""
echo "=== Summary ==="
for entry in "${VERSIONS[@]}"; do
    IFS=: read WINE_VERSION _ <<< "$entry"
    if [ -f "$OUTPUT_BASE/$WINE_VERSION/wined3d.dll" ]; then
        echo "  ✓ $WINE_VERSION"
    else
        echo "  ✗ $WINE_VERSION (missing)"
    fi
done

#!/usr/bin/env bash
# Build the zest Zig binary and package it into a platform-specific Python wheel.
#
# Usage:
#   ./scripts/build-wheel.sh                  # build for current platform
#   ./scripts/build-wheel.sh x86_64-linux     # cross-compile for target
#   ./scripts/build-wheel.sh aarch64-linux    # cross-compile for ARM
#   ./scripts/build-wheel.sh x86_64-macos     # cross-compile for Intel Mac
#   ./scripts/build-wheel.sh aarch64-macos    # cross-compile for Apple Silicon
#   ./scripts/build-wheel.sh all              # build all platform wheels
#
# Output: python/dist/zest_transfer-*-<platform>.whl

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
PYTHON_DIR="$ROOT_DIR/python"
BIN_DIR="$PYTHON_DIR/zest/_bin"
VERSION="0.4.1"

build_wheel() {
    local TARGET="$1"
    local ZIG_TARGET=""
    local PLATFORM_TAG=""
    local BINARY_NAME="zest"

    case "$TARGET" in
        native)
            ZIG_TARGET=""
            # Detect current platform
            ARCH="$(uname -m)"
            OS="$(uname -s)"
            if [ "$OS" = "Linux" ]; then
                if [ "$ARCH" = "x86_64" ]; then
                    PLATFORM_TAG="manylinux_2_17_x86_64.manylinux2014_x86_64"
                elif [ "$ARCH" = "aarch64" ]; then
                    PLATFORM_TAG="manylinux_2_17_aarch64.manylinux2014_aarch64"
                fi
            elif [ "$OS" = "Darwin" ]; then
                if [ "$ARCH" = "x86_64" ]; then
                    PLATFORM_TAG="macosx_11_0_x86_64"
                elif [ "$ARCH" = "arm64" ]; then
                    PLATFORM_TAG="macosx_11_0_arm64"
                fi
            fi
            ;;
        x86_64-linux)
            ZIG_TARGET="-Dtarget=x86_64-linux-gnu"
            PLATFORM_TAG="manylinux_2_17_x86_64.manylinux2014_x86_64"
            ;;
        aarch64-linux)
            ZIG_TARGET="-Dtarget=aarch64-linux-gnu"
            PLATFORM_TAG="manylinux_2_17_aarch64.manylinux2014_aarch64"
            ;;
        x86_64-macos)
            ZIG_TARGET="-Dtarget=x86_64-macos-none"
            PLATFORM_TAG="macosx_11_0_x86_64"
            ;;
        aarch64-macos)
            ZIG_TARGET="-Dtarget=aarch64-macos-none"
            PLATFORM_TAG="macosx_11_0_arm64"
            ;;
        *)
            echo "Unknown target: $TARGET"
            echo "Supported: native, x86_64-linux, aarch64-linux, x86_64-macos, aarch64-macos, all"
            exit 1
            ;;
    esac

    if [ -z "$PLATFORM_TAG" ]; then
        echo "Could not determine platform tag for target: $TARGET"
        exit 1
    fi

    echo "=== Building zest binary (target: $TARGET) ==="
    cd "$ROOT_DIR"

    if [ -n "$ZIG_TARGET" ]; then
        zig build -Doptimize=ReleaseFast $ZIG_TARGET
    else
        zig build -Doptimize=ReleaseFast
    fi

    local BINARY="$ROOT_DIR/zig-out/bin/$BINARY_NAME"
    echo "Binary size: $(du -h "$BINARY" | cut -f1)"

    # Copy binary into Python package
    mkdir -p "$BIN_DIR"
    cp "$BINARY" "$BIN_DIR/zest"
    chmod +x "$BIN_DIR/zest"

    echo "=== Building Python wheel (platform: $PLATFORM_TAG) ==="
    cd "$PYTHON_DIR"

    # Clean previous builds (keep dist/)
    rm -rf build/ *.egg-info zest/*.egg-info zest_transfer.egg-info/

    # Build generic wheel first
    python -m build --wheel --no-isolation 2>/dev/null || python -m build --wheel

    # Retag the wheel with the correct platform
    local GENERIC_WHL
    GENERIC_WHL="$(ls dist/zest_transfer-${VERSION}-py3-none-any.whl 2>/dev/null || true)"
    if [ -n "$GENERIC_WHL" ]; then
        python -m wheel tags --platform-tag="$PLATFORM_TAG" --remove "$GENERIC_WHL"
    fi

    # Clean up build artifacts
    rm -rf build/ *.egg-info zest/*.egg-info zest_transfer.egg-info/

    echo "  Built: $(ls dist/zest_transfer-${VERSION}-py3-none-${PLATFORM_TAG}.whl 2>/dev/null || echo 'see dist/')"
}

TARGET="${1:-native}"

if [ "$TARGET" = "all" ]; then
    mkdir -p "$PYTHON_DIR/dist"
    for t in x86_64-linux aarch64-linux x86_64-macos aarch64-macos; do
        build_wheel "$t"
    done
    echo ""
    echo "=== All wheels built ==="
    ls -lh "$PYTHON_DIR/dist/"*.whl
else
    mkdir -p "$PYTHON_DIR/dist"
    build_wheel "$TARGET"
fi

echo ""
echo "=== Done ==="
echo ""
echo "Wheels:"
ls "$PYTHON_DIR/dist/"*.whl 2>/dev/null || echo "  (none found)"
echo ""
echo "To publish to PyPI:"
echo "  twine upload python/dist/*.whl"
echo ""
echo "Users can then install with:"
echo "  pip install zest-transfer"

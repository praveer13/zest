#!/usr/bin/env bash
# Build the zest Zig binary and package it into a Python wheel.
#
# Usage:
#   ./scripts/build-wheel.sh                  # build for current platform
#   ./scripts/build-wheel.sh x86_64-linux     # cross-compile for target
#   ./scripts/build-wheel.sh aarch64-linux    # cross-compile for ARM
#
# Output: python/dist/zest_transfer-*.whl

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
PYTHON_DIR="$ROOT_DIR/python"
BIN_DIR="$PYTHON_DIR/zest/_bin"

TARGET="${1:-native}"

echo "=== Building zest binary (target: $TARGET) ==="

cd "$ROOT_DIR"

if [ "$TARGET" = "native" ]; then
    zig build -Doptimize=ReleaseFast
    BINARY="$ROOT_DIR/zig-out/bin/zest"
elif [ "$TARGET" = "x86_64-linux" ]; then
    zig build -Doptimize=ReleaseFast -Dtarget=x86_64-linux-gnu
    BINARY="$ROOT_DIR/zig-out/bin/zest"
elif [ "$TARGET" = "aarch64-linux" ]; then
    zig build -Doptimize=ReleaseFast -Dtarget=aarch64-linux-gnu
    BINARY="$ROOT_DIR/zig-out/bin/zest"
else
    echo "Unknown target: $TARGET"
    echo "Supported: native, x86_64-linux, aarch64-linux"
    exit 1
fi

echo "Binary size: $(du -h "$BINARY" | cut -f1)"

# Copy binary into Python package
mkdir -p "$BIN_DIR"
cp "$BINARY" "$BIN_DIR/zest"
chmod +x "$BIN_DIR/zest"

echo "=== Building Python wheel ==="

cd "$PYTHON_DIR"

# Clean previous builds
rm -rf dist/ build/ *.egg-info zest/*.egg-info

# Build wheel
python -m build --wheel 2>/dev/null || pip install build && python -m build --wheel

echo ""
echo "=== Done ==="
echo "Wheel: $(ls dist/*.whl)"
echo ""
echo "Install on test servers:"
echo "  scp dist/*.whl server-a:"
echo "  scp dist/*.whl server-b:"
echo "  ssh server-a 'pip install zest_transfer-*.whl'"
echo "  ssh server-b 'pip install zest_transfer-*.whl'"
echo ""
echo "Test P2P:"
echo "  # Server A: download model and start seeding"
echo "  ssh server-a 'zest pull gpt2 && zest serve'"
echo ""
echo "  # Server B: download from Server A via P2P"
echo "  ssh server-b 'zest pull gpt2 --peer <server-a-ip>:6881'"

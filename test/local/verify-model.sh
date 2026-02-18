#!/usr/bin/env bash
# verify-model.sh — Pull a model with zest, load with transformers, run inference.
# Validates end-to-end data integrity: zest download → model load → text generation.
#
# Usage: ./test/local/verify-model.sh
# Requires: zig (or nix), python3 + transformers + torch, HF_TOKEN

set -euo pipefail

REPO="openai-community/gpt2"
PROMPT="The quick brown fox"
MIN_PARAMS=100000000  # GPT-2 has ~124M params

# ── Colors ──
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info()  { echo -e "${YELLOW}[INFO]${NC} $*"; }
pass()  { echo -e "${GREEN}[PASS]${NC} $*"; }
fail()  { echo -e "${RED}[FAIL]${NC} $*"; exit 1; }

# ── Cleanup ──
TMPDIR=""
cleanup() {
    if [ -n "$TMPDIR" ] && [ -d "$TMPDIR" ]; then
        rm -rf "$TMPDIR"
        info "Cleaned up $TMPDIR"
    fi
}
trap cleanup EXIT

# ── Check dependencies ──
info "Checking dependencies..."

# Zig (direct or via nix)
if command -v zig &>/dev/null; then
    ZIG=zig
elif [ -d "/nix/store" ]; then
    ZIG=$(ls -d /nix/store/*zig-0.16*/bin/zig 2>/dev/null | head -1 || true)
    if [ -z "$ZIG" ]; then
        fail "Zig 0.16 not found. Run: nix develop"
    fi
else
    fail "zig not found. Install Zig 0.16+ or use nix develop"
fi
info "Using zig: $($ZIG version)"

# Python + transformers + torch
python3 -c "import transformers, torch" 2>/dev/null || \
    fail "Missing Python deps. Run: pip install transformers torch"

# HF_TOKEN
if [ -z "${HF_TOKEN:-}" ]; then
    if [ -f "$HOME/.cache/huggingface/token" ]; then
        export HF_TOKEN=$(cat "$HOME/.cache/huggingface/token" | tr -d '[:space:]')
    else
        fail "HF_TOKEN not set and ~/.cache/huggingface/token not found"
    fi
fi
info "HF_TOKEN is set"

# ── Build zest ──
cd "$(git -C "$(dirname "$0")" rev-parse --show-toplevel)"
if [ -x "$(pwd)/zig-out/bin/zest" ] && [ -z "${ZEST_FORCE_BUILD:-}" ]; then
    ZEST="$(pwd)/zig-out/bin/zest"
    info "Using pre-built binary: $ZEST"
else
    info "Building zest (ReleaseFast)..."
    $ZIG build -Doptimize=ReleaseFast 2>&1 | tail -5
    ZEST="$(pwd)/zig-out/bin/zest"
    [ -x "$ZEST" ] || fail "Build failed: $ZEST not found"
    info "Built: $ZEST"
fi

# ── Set up isolated environment ──
TMPDIR=$(mktemp -d /tmp/zest-verify-XXXXXX)
export HF_HOME="$TMPDIR/hf"
export ZEST_CACHE_DIR="$TMPDIR/zest"
mkdir -p "$HF_HOME" "$ZEST_CACHE_DIR"

# Write HF token where zest can find it
mkdir -p "$TMPDIR/.cache/huggingface"
echo "$HF_TOKEN" > "$TMPDIR/.cache/huggingface/token"

info "HF_HOME=$HF_HOME"
info "ZEST_CACHE_DIR=$ZEST_CACHE_DIR"

# ── Pull model ──
info "Pulling $REPO (CDN-only)..."
HOME="$TMPDIR" $ZEST pull "$REPO" --no-p2p 2>&1 | tee "$TMPDIR/pull.log"

# Find the snapshot directory
SNAPSHOT_DIR=$(find "$HF_HOME" -name "model.safetensors" -printf '%h\n' 2>/dev/null | head -1)
if [ -z "$SNAPSHOT_DIR" ]; then
    fail "Model files not found after pull"
fi
info "Model at: $SNAPSHOT_DIR"

# ── Load model + run inference ──
info "Loading model and running inference..."
RESULT=$(python3 -c "
import os, sys
os.environ['HF_HUB_OFFLINE'] = '1'
os.environ['TRANSFORMERS_OFFLINE'] = '1'

from transformers import AutoModelForCausalLM, AutoTokenizer
import torch

model_path = '$SNAPSHOT_DIR'
print(f'Loading from: {model_path}', file=sys.stderr)

tokenizer = AutoTokenizer.from_pretrained(model_path)
model = AutoModelForCausalLM.from_pretrained(model_path, torch_dtype=torch.float32)

# Check param count
num_params = sum(p.numel() for p in model.parameters())
print(f'Parameters: {num_params:,}', file=sys.stderr)
assert num_params > $MIN_PARAMS, f'Too few params: {num_params}'

# Generate text
inputs = tokenizer('$PROMPT', return_tensors='pt')
with torch.no_grad():
    outputs = model.generate(**inputs, max_new_tokens=20, do_sample=False)
text = tokenizer.decode(outputs[0], skip_special_tokens=True)
print(text)
" 2>&1)

info "Model output:"
echo "$RESULT"

# ── Validate ──
if echo "$RESULT" | grep -q "$PROMPT"; then
    pass "Model loaded and generated text starting with prompt"
else
    fail "Output does not contain prompt: '$PROMPT'"
fi

if echo "$RESULT" | grep -q "Parameters:"; then
    PARAMS=$(echo "$RESULT" | grep "Parameters:" | grep -oP '[0-9,]+' | tr -d ',')
    if [ "$PARAMS" -gt "$MIN_PARAMS" ]; then
        pass "Parameter count OK: $PARAMS > $MIN_PARAMS"
    else
        fail "Parameter count too low: $PARAMS <= $MIN_PARAMS"
    fi
fi

echo ""
pass "All checks passed — zest pull + model inference verified!"

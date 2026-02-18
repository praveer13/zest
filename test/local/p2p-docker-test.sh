#!/usr/bin/env bash
# p2p-docker-test.sh — Docker-based P2P test for zest.
# Runs seeder + leecher in separate containers on a Docker bridge network.
# Validates that the leecher fetches xorbs from the seeder via P2P.
#
# Usage: ./test/local/p2p-docker-test.sh
# Requires: docker, HF_TOKEN (or ~/.cache/huggingface/token)

set -euo pipefail

REPO="openai-community/gpt2"
IMAGE_NAME="zest-p2p-test"
NETWORK_NAME="zest-p2p-test"
SEEDER_NAME="zest-seeder"
LEECHER_NAME="zest-leecher"
VOLUME_HF="zest-test-hf-cache"
VOLUME_ZEST="zest-test-zest-cache"
BT_PORT=6881
HTTP_PORT=9847
READINESS_TIMEOUT=60  # seconds

# ── Colors ──
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

info()  { echo -e "${YELLOW}[INFO]${NC} $*"; }
pass()  { echo -e "${GREEN}[PASS]${NC} $*"; }
fail()  { echo -e "${RED}[FAIL]${NC} $*"; exit 1; }
step()  { echo -e "\n${CYAN}── $* ──${NC}"; }

# ── Cleanup ──
cleanup() {
    info "Cleaning up..."
    docker rm -f "$SEEDER_NAME" "$LEECHER_NAME" 2>/dev/null || true
    docker volume rm -f "$VOLUME_HF" "$VOLUME_ZEST" 2>/dev/null || true
    docker network rm "$NETWORK_NAME" 2>/dev/null || true
    docker rmi -f "$IMAGE_NAME" 2>/dev/null || true
    info "Cleanup complete"
}
trap cleanup EXIT

# ── Check dependencies ──
step "Checking dependencies"

if ! command -v docker &>/dev/null; then
    fail "docker not found. Install Docker: https://docs.docker.com/get-docker/"
fi

# Verify docker is running
docker info &>/dev/null || fail "Docker daemon not running. Start it with: sudo systemctl start docker"

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
step "Building zest"

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

cd "$(git -C "$(dirname "$0")" rev-parse --show-toplevel)"
if [ -x "$(pwd)/zig-out/bin/zest" ] && [ -z "${ZEST_FORCE_BUILD:-}" ]; then
    ZEST_BIN="$(pwd)/zig-out/bin/zest"
    info "Using pre-built binary: $ZEST_BIN ($($ZEST_BIN version 2>/dev/null || echo 'unknown'))"
else
    info "Building zest (ReleaseFast)..."
    $ZIG build -Doptimize=ReleaseFast 2>&1 | tail -5
    ZEST_BIN="$(pwd)/zig-out/bin/zest"
    [ -x "$ZEST_BIN" ] || fail "Build failed: $ZEST_BIN not found"
    info "Built: $ZEST_BIN ($($ZEST_BIN version 2>/dev/null || echo 'unknown'))"
fi

# ── Build Docker image ──
step "Building Docker image"

docker build -t "$IMAGE_NAME" -f - . <<'DOCKERFILE'
FROM debian:bookworm-slim
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates && rm -rf /var/lib/apt/lists/*
COPY zig-out/bin/zest /usr/local/bin/zest
RUN chmod +x /usr/local/bin/zest
DOCKERFILE

info "Docker image built: $IMAGE_NAME"

# ── Create network and volumes ──
step "Setting up Docker network and volumes"

docker network create "$NETWORK_NAME" 2>/dev/null || true
docker volume create "$VOLUME_HF" >/dev/null
docker volume create "$VOLUME_ZEST" >/dev/null
info "Network: $NETWORK_NAME, Volumes: $VOLUME_HF, $VOLUME_ZEST"

# ── Seeder: pull model (CDN-only) ──
step "Seeder: pulling $REPO (CDN-only)"

docker run --rm \
    --name "${SEEDER_NAME}-pull" \
    --network "$NETWORK_NAME" \
    -e "HF_TOKEN=$HF_TOKEN" \
    -e "HF_HOME=/cache/hf" \
    -e "ZEST_CACHE_DIR=/cache/zest" \
    -v "$VOLUME_HF:/cache/hf" \
    -v "$VOLUME_ZEST:/cache/zest" \
    "$IMAGE_NAME" \
    zest pull "$REPO" --no-p2p

info "Seeder pull complete"

# ── Seeder: start serving ──
step "Seeder: starting server"

docker run -d \
    --name "$SEEDER_NAME" \
    --network "$NETWORK_NAME" \
    -e "HF_TOKEN=$HF_TOKEN" \
    -e "HF_HOME=/cache/hf" \
    -e "ZEST_CACHE_DIR=/cache/zest" \
    -v "$VOLUME_HF:/cache/hf" \
    -v "$VOLUME_ZEST:/cache/zest" \
    "$IMAGE_NAME" \
    zest serve --listen-port "$BT_PORT" --http-port "$HTTP_PORT"

# Wait for server readiness
info "Waiting for seeder to be ready (timeout: ${READINESS_TIMEOUT}s)..."
ELAPSED=0
while [ $ELAPSED -lt $READINESS_TIMEOUT ]; do
    if docker logs "$SEEDER_NAME" 2>&1 | grep -q "Server running. Press Ctrl+C to stop."; then
        break
    fi
    sleep 1
    ELAPSED=$((ELAPSED + 1))
done

if [ $ELAPSED -ge $READINESS_TIMEOUT ]; then
    info "Seeder logs:"
    docker logs "$SEEDER_NAME" 2>&1 | tail -20
    fail "Seeder did not become ready within ${READINESS_TIMEOUT}s"
fi

info "Seeder ready (took ${ELAPSED}s)"
docker logs "$SEEDER_NAME" 2>&1 | grep -E "(Cached xorbs|BT listen|HTTP API)"

# Resolve seeder IP (zest --peer requires IP:port, not hostname:port)
SEEDER_IP=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$SEEDER_NAME")
[ -n "$SEEDER_IP" ] || fail "Could not resolve seeder container IP"
info "Seeder IP: $SEEDER_IP"

# ── Leecher: pull model via P2P ──
step "Leecher: pulling $REPO (with P2P from seeder)"

LEECHER_OUTPUT=$(docker run --rm \
    --name "$LEECHER_NAME" \
    --network "$NETWORK_NAME" \
    -e "HF_TOKEN=$HF_TOKEN" \
    -e "HF_HOME=/cache/leecher-hf" \
    -e "ZEST_CACHE_DIR=/cache/leecher-zest" \
    "$IMAGE_NAME" \
    zest pull "$REPO" --peer "${SEEDER_IP}:${BT_PORT}" 2>&1) || true

echo "$LEECHER_OUTPUT"

# ── Parse results ──
step "Parsing results"

# Parse from XetBridge stats (the authoritative source for xorb fetch method)
# Format: "  From peers:   N" and "  From CDN:     N"
XORBS_FROM_PEERS=$(echo "$LEECHER_OUTPUT" | grep -oP 'From peers:\s+\K[0-9]+' | head -1 || echo "0")
XORBS_FROM_CDN=$(echo "$LEECHER_OUTPUT" | grep -oP 'From CDN:\s+\K[0-9]+' | head -1 || echo "0")
TOTAL_XORBS=$(echo "$LEECHER_OUTPUT" | grep -oP 'Total xorbs:\s+\K[0-9]+' | head -1 || echo "0")

# ── Summary ──
step "Results"

echo ""
echo "┌────────────────────────────────────┐"
echo "│         P2P Test Results           │"
echo "├────────────────────────────────────┤"
printf "│  Total xorbs:    %-16s │\n" "$TOTAL_XORBS"
printf "│  From peers:     %-16s │\n" "$XORBS_FROM_PEERS"
printf "│  From CDN:       %-16s │\n" "$XORBS_FROM_CDN"
echo "└────────────────────────────────────┘"
echo ""

# ── Assertions ──
if [ -z "$XORBS_FROM_PEERS" ] || [ "$XORBS_FROM_PEERS" = "0" ]; then
    info "Seeder logs:"
    docker logs "$SEEDER_NAME" 2>&1 | tail -30
    fail "No xorbs fetched from peers (expected > 0)"
fi

if [ "$XORBS_FROM_CDN" = "0" ]; then
    pass "100% P2P transfer — all $XORBS_FROM_PEERS xorbs from peers, 0 from CDN"
else
    TOTAL=$((XORBS_FROM_PEERS + XORBS_FROM_CDN))
    if [ "$TOTAL" -gt 0 ]; then
        PCT=$((XORBS_FROM_PEERS * 100 / TOTAL))
        pass "P2P transfer: $XORBS_FROM_PEERS/$TOTAL xorbs from peers (${PCT}%)"
    fi
fi

echo ""
pass "P2P Docker test passed!"

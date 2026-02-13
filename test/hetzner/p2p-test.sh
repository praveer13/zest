#!/usr/bin/env bash
# zest P2P integration test on Hetzner Cloud.
#
# Provisions 3 CX22 instances, deploys a cross-compiled zest binary,
# runs CDN-only and P2P download tests, reports results, and tears down.
#
# Usage:
#   ./test/hetzner/p2p-test.sh all        # Full lifecycle (~10 min, ~EUR 0.05)
#   ./test/hetzner/p2p-test.sh provision   # Create 3 nodes + firewall
#   ./test/hetzner/p2p-test.sh deploy      # Cross-compile + deploy binary
#   ./test/hetzner/p2p-test.sh test        # Run P2P test suite
#   ./test/hetzner/p2p-test.sh report      # Print results summary
#   ./test/hetzner/p2p-test.sh teardown    # Destroy all resources
#   ./test/hetzner/p2p-test.sh status      # Show node state
#
# Prerequisites:
#   - hcloud CLI (brew install hcloud / nix-env -i hcloud)
#   - HCLOUD_TOKEN env var (Hetzner Cloud API token)
#   - HF_TOKEN env var (HuggingFace token)
#   - zig compiler (for cross-compilation)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
STATE_DIR="$SCRIPT_DIR/.state"
RESULTS_DIR="$STATE_DIR/results"

# ── Configuration ──

NODE_COUNT=3
NODE_TYPE="cpx22"               # 2 vCPU, 4GB RAM, ~EUR 0.01/hr
LOCATION="nbg1"                 # Nuremberg — low inter-node latency
IMAGE="ubuntu-24.04"
NODE_PREFIX="zest-p2p-test"
FIREWALL_NAME="zest-p2p-fw"
SSH_KEY_NAME="zest-p2p-test-key"
TEST_MODEL="openai-community/gpt2"
BT_PORT=6881
HTTP_PORT=9847

SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -o BatchMode=yes -o LogLevel=ERROR"

# ── Utilities ──

log()  { printf "[%s] %s\n" "$(date +%H:%M:%S)" "$*"; }
err()  { printf "[%s] ERROR: %s\n" "$(date +%H:%M:%S)" "$*" >&2; }
die()  { err "$@"; exit 1; }

check_deps() {
    for cmd in hcloud ssh scp jq zig; do
        command -v "$cmd" >/dev/null 2>&1 || die "Missing required command: $cmd"
    done
    [[ -n "${HCLOUD_TOKEN:-}" ]]  || die "HCLOUD_TOKEN not set. Get one from https://console.hetzner.cloud/"
    [[ -n "${HF_TOKEN:-}" ]]      || die "HF_TOKEN not set. Get one from https://huggingface.co/settings/tokens"
}

ensure_state_dir() {
    mkdir -p "$STATE_DIR" "$RESULTS_DIR"
}

ssh_key_path() { echo "$STATE_DIR/ssh_key"; }

node_ip() {
    jq -r ".nodes[$1].ip" "$STATE_DIR/nodes.json"
}

node_id() {
    jq -r ".nodes[$1].id" "$STATE_DIR/nodes.json"
}

node_name() {
    echo "${NODE_PREFIX}-$1"
}

ssh_node() {
    local n=$1; shift
    ssh $SSH_OPTS -i "$(ssh_key_path)" "root@$(node_ip "$n")" "$@"
}

scp_to() {
    local n=$1 src=$2 dst=$3
    scp $SSH_OPTS -i "$(ssh_key_path)" "$src" "root@$(node_ip "$n"):$dst"
}

wait_ssh() {
    local n=$1 ip
    ip=$(node_ip "$n")
    log "Waiting for SSH on node $n ($ip)..."
    for attempt in $(seq 1 30); do
        if ssh $SSH_OPTS -i "$(ssh_key_path)" "root@$ip" true 2>/dev/null; then
            log "  Node $n SSH ready"
            return 0
        fi
        sleep 3
    done
    die "Timeout waiting for SSH on node $n ($ip)"
}

# Parse wall-clock time from /usr/bin/time -v output (format: h:mm:ss or m:ss.ss)
parse_time() {
    grep 'Elapsed.*wall clock' "$1" | sed 's/.*): //' || echo "N/A"
}

# Convert time string to seconds (handles h:mm:ss and m:ss.ss)
time_to_seconds() {
    local t="$1"
    if [[ "$t" == "N/A" ]]; then echo "0"; return; fi
    # Remove leading/trailing whitespace
    t=$(echo "$t" | xargs)
    local parts
    IFS=':' read -ra parts <<< "$t"
    if [[ ${#parts[@]} -eq 3 ]]; then
        echo "${parts[0]} * 3600 + ${parts[1]} * 60 + ${parts[2]}" | bc
    elif [[ ${#parts[@]} -eq 2 ]]; then
        echo "${parts[0]} * 60 + ${parts[1]}" | bc
    else
        echo "$t"
    fi
}

# ── Provision ──

provision() {
    ensure_state_dir
    log "=== Provisioning $NODE_COUNT nodes ==="

    # Step 1: SSH key
    if [[ ! -f "$(ssh_key_path)" ]]; then
        log "Generating SSH keypair..."
        ssh-keygen -t ed25519 -f "$(ssh_key_path)" -N "" -q
    fi

    # Upload to Hetzner (skip if exists)
    if ! hcloud ssh-key describe "$SSH_KEY_NAME" &>/dev/null; then
        log "Uploading SSH key to Hetzner..."
        hcloud ssh-key create --name "$SSH_KEY_NAME" --public-key-from-file "$(ssh_key_path).pub"
    fi

    # Step 2: Firewall
    local fw_id=""
    if hcloud firewall describe "$FIREWALL_NAME" &>/dev/null; then
        fw_id=$(hcloud firewall describe "$FIREWALL_NAME" -o json | jq -r '.id')
        log "Firewall $FIREWALL_NAME exists (id: $fw_id)"
    else
        log "Creating firewall..."
        hcloud firewall create --name "$FIREWALL_NAME"
        fw_id=$(hcloud firewall describe "$FIREWALL_NAME" -o json | jq -r '.id')

        # Allow SSH
        hcloud firewall add-rule "$FIREWALL_NAME" --direction in --protocol tcp --port 22 --source-ips 0.0.0.0/0 --source-ips ::/0
        # Allow BT peer (TCP)
        hcloud firewall add-rule "$FIREWALL_NAME" --direction in --protocol tcp --port "$BT_PORT" --source-ips 0.0.0.0/0 --source-ips ::/0
        # Allow DHT (UDP)
        hcloud firewall add-rule "$FIREWALL_NAME" --direction in --protocol udp --port "$BT_PORT" --source-ips 0.0.0.0/0 --source-ips ::/0
        log "Firewall created with rules for SSH, BT, DHT"
    fi

    # Step 3: Create nodes
    local nodes_json='{"nodes":[],"firewall_id":"'"$fw_id"'","created_at":"'"$(date -u +%Y-%m-%dT%H:%M:%SZ)"'"}'

    for n in $(seq 0 $((NODE_COUNT - 1))); do
        local name
        name=$(node_name "$n")

        if hcloud server describe "$name" &>/dev/null; then
            log "Node $name already exists"
            local info
            info=$(hcloud server describe "$name" -o json)
            local id ip
            id=$(echo "$info" | jq -r '.id')
            ip=$(echo "$info" | jq -r '.public_net.ipv4.ip')
            nodes_json=$(echo "$nodes_json" | jq ".nodes += [{\"id\": $id, \"name\": \"$name\", \"ip\": \"$ip\"}]")
        else
            log "Creating $name ($NODE_TYPE in $LOCATION)..."
            hcloud server create \
                --name "$name" \
                --type "$NODE_TYPE" \
                --image "$IMAGE" \
                --location "$LOCATION" \
                --ssh-key "$SSH_KEY_NAME" \
                --firewall "$FIREWALL_NAME" \
                --poll-interval 2s

            local info
            info=$(hcloud server describe "$name" -o json)
            local id ip
            id=$(echo "$info" | jq -r '.id')
            ip=$(echo "$info" | jq -r '.public_net.ipv4.ip')
            nodes_json=$(echo "$nodes_json" | jq ".nodes += [{\"id\": $id, \"name\": \"$name\", \"ip\": \"$ip\"}]")
            log "  Created $name: $ip (id: $id)"
        fi
    done

    echo "$nodes_json" | jq . > "$STATE_DIR/nodes.json"
    log "State saved to $STATE_DIR/nodes.json"

    # Step 4: Wait for SSH
    for n in $(seq 0 $((NODE_COUNT - 1))); do
        wait_ssh "$n" &
    done
    wait
    log "All nodes ready"
}

# ── Deploy ──

deploy() {
    [[ -f "$STATE_DIR/nodes.json" ]] || die "No state file. Run 'provision' first."
    log "=== Deploying zest binary ==="

    # Cross-compile
    log "Cross-compiling for x86_64-linux (ReleaseFast)..."
    (cd "$ROOT_DIR" && zig build -Dtarget=x86_64-linux -Doptimize=ReleaseFast)
    local binary="$ROOT_DIR/zig-out/bin/zest"
    [[ -f "$binary" ]] || die "Binary not found at $binary"
    log "  Binary size: $(du -h "$binary" | cut -f1)"

    # Deploy to all nodes in parallel
    for n in $(seq 0 $((NODE_COUNT - 1))); do
        (
            local ip
            ip=$(node_ip "$n")
            log "Deploying to node $n ($ip)..."

            scp_to "$n" "$binary" /usr/local/bin/zest
            ssh_node "$n" "chmod +x /usr/local/bin/zest"

            # Verify
            local ver
            ver=$(ssh_node "$n" "zest version 2>&1" || true)
            log "  Node $n: $ver"

            # Set up HF token
            ssh_node "$n" "mkdir -p /root/.cache/huggingface && printf '%s' '$HF_TOKEN' > /root/.cache/huggingface/token"

            log "  Node $n deployed"
        ) &
    done
    wait
    log "All nodes deployed"
}

# ── Test suite ──

test_all() {
    [[ -f "$STATE_DIR/nodes.json" ]] || die "No state file. Run 'provision' first."
    ensure_state_dir

    local node_b_ip node_c_ip
    node_b_ip=$(node_ip 1)
    node_c_ip=$(node_ip 2)

    # ── Test 1: CDN-only baseline on Node A ──
    log "=== Test 1: CDN-only baseline (Node A) ==="
    ssh_node 0 "rm -rf /root/.cache/zest /root/.cache/huggingface/hub" || true

    ssh_node 0 "export HF_TOKEN='$HF_TOKEN'; /usr/bin/time -v zest pull $TEST_MODEL --no-p2p" \
        > "$RESULTS_DIR/test1_cdn_baseline.txt" 2>&1 || true

    local cdn_time
    cdn_time=$(parse_time "$RESULTS_DIR/test1_cdn_baseline.txt")
    log "CDN-only time: $cdn_time"

    # ── Test 2: Seed Nodes B and C ──
    log "=== Test 2: Seeding Nodes B & C ==="
    for n in 1 2; do
        (
            log "  Node $n: pulling model (CDN-only)..."
            ssh_node "$n" "rm -rf /root/.cache/zest /root/.cache/huggingface/hub" || true
            ssh_node "$n" "export HF_TOKEN='$HF_TOKEN'; zest pull $TEST_MODEL --no-p2p" \
                > "$RESULTS_DIR/test2_seed_node${n}.txt" 2>&1 || true
            log "  Node $n: pull complete, starting server..."

            # Start zest serve in background
            ssh_node "$n" "export HF_TOKEN='$HF_TOKEN'; nohup zest serve --listen-port $BT_PORT --http-port $HTTP_PORT > /root/zest-serve.log 2>&1 &"
            sleep 3

            # Verify server is running (check if port is listening)
            local listening
            listening=$(ssh_node "$n" "ss -tlnp | grep :$BT_PORT || echo 'not listening'" 2>/dev/null || echo "check failed")
            log "  Node $n server: $listening"
        ) &
    done
    wait
    log "Seeders ready"

    # Give servers a moment to stabilize
    sleep 2

    # ── Test 3: P2P with 2 peers ──
    log "=== Test 3: P2P pull with 2 peers (Node A) ==="
    ssh_node 0 "rm -rf /root/.cache/zest /root/.cache/huggingface/hub" || true

    ssh_node 0 "export HF_TOKEN='$HF_TOKEN'; /usr/bin/time -v zest pull $TEST_MODEL --peer ${node_b_ip}:${BT_PORT} --peer ${node_c_ip}:${BT_PORT}" \
        > "$RESULTS_DIR/test3_p2p_2peers.txt" 2>&1 || true

    local p2p_time
    p2p_time=$(parse_time "$RESULTS_DIR/test3_p2p_2peers.txt")
    log "P2P (2 peers) time: $p2p_time"

    # ── Test 4: P2P with 1 peer ──
    log "=== Test 4: P2P pull with 1 peer (Node A) ==="
    ssh_node 0 "rm -rf /root/.cache/zest /root/.cache/huggingface/hub" || true

    ssh_node 0 "export HF_TOKEN='$HF_TOKEN'; /usr/bin/time -v zest pull $TEST_MODEL --peer ${node_b_ip}:${BT_PORT}" \
        > "$RESULTS_DIR/test4_p2p_1peer.txt" 2>&1 || true

    local single_time
    single_time=$(parse_time "$RESULTS_DIR/test4_p2p_1peer.txt")
    log "P2P (1 peer) time: $single_time"

    # ── Collect server logs ──
    for n in 1 2; do
        ssh_node "$n" "cat /root/zest-serve.log 2>/dev/null" \
            > "$RESULTS_DIR/server_node${n}.log" 2>&1 || true
    done

    log "=== All tests complete ==="
    report
}

# ── Report ──

report() {
    ensure_state_dir
    log ""
    log "=== P2P Integration Test Results ==="
    log ""

    local cdn_time p2p_time single_time
    cdn_time=$(parse_time "$RESULTS_DIR/test1_cdn_baseline.txt" 2>/dev/null || echo "N/A")
    p2p_time=$(parse_time "$RESULTS_DIR/test3_p2p_2peers.txt" 2>/dev/null || echo "N/A")
    single_time=$(parse_time "$RESULTS_DIR/test4_p2p_1peer.txt" 2>/dev/null || echo "N/A")

    # Parse P2P stats from zest output
    local p2p_ratio xorbs_peers xorbs_cdn
    p2p_ratio=$(grep 'P2P ratio' "$RESULTS_DIR/test3_p2p_2peers.txt" 2>/dev/null | tail -1 | awk '{print $NF}' || echo "N/A")
    xorbs_peers=$(grep 'From peers' "$RESULTS_DIR/test3_p2p_2peers.txt" 2>/dev/null | tail -1 | awk '{print $NF}' || echo "N/A")
    xorbs_cdn=$(grep 'From CDN' "$RESULTS_DIR/test3_p2p_2peers.txt" 2>/dev/null | tail -1 | awk '{print $NF}' || echo "N/A")

    # Calculate speedup
    local cdn_secs p2p_secs speedup
    cdn_secs=$(time_to_seconds "$cdn_time")
    p2p_secs=$(time_to_seconds "$p2p_time")

    if [[ "$p2p_secs" != "0" ]] && command -v bc &>/dev/null; then
        speedup=$(echo "scale=2; $cdn_secs / $p2p_secs" | bc 2>/dev/null || echo "N/A")
    else
        speedup="N/A"
    fi

    printf "\n"
    printf "  +-------------------------------------------------+\n"
    printf "  |  zest P2P Integration Test Results              |\n"
    printf "  +-------------------------------------------------+\n"
    printf "  |  Model:             %-28s|\n" "$TEST_MODEL"
    printf "  |  Nodes:             3x Hetzner %s (%s)       |\n" "$NODE_TYPE" "$LOCATION"
    printf "  +-------------------------------------------------+\n"
    printf "  |  CDN-only (baseline):  %-25s|\n" "$cdn_time"
    printf "  |  P2P (2 peers):        %-25s|\n" "$p2p_time"
    printf "  |  P2P (1 peer):         %-25s|\n" "$single_time"
    printf "  |  Speedup (2 peers):    %-25s|\n" "${speedup}x"
    printf "  +-------------------------------------------------+\n"
    printf "  |  Xorbs from peers:     %-25s|\n" "$xorbs_peers"
    printf "  |  Xorbs from CDN:       %-25s|\n" "$xorbs_cdn"
    printf "  |  P2P ratio:            %-25s|\n" "$p2p_ratio"
    printf "  +-------------------------------------------------+\n"
    printf "\n"

    # JSON summary
    cat > "$RESULTS_DIR/summary.json" <<EOJSON
{
    "model": "$TEST_MODEL",
    "node_type": "$NODE_TYPE",
    "location": "$LOCATION",
    "cdn_time": "$cdn_time",
    "p2p_2peer_time": "$p2p_time",
    "p2p_1peer_time": "$single_time",
    "cdn_seconds": $cdn_secs,
    "p2p_2peer_seconds": $p2p_secs,
    "speedup_2peers": "$speedup",
    "p2p_ratio": "$p2p_ratio",
    "xorbs_from_peers": "$xorbs_peers",
    "xorbs_from_cdn": "$xorbs_cdn",
    "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOJSON
    log "Results saved to $RESULTS_DIR/summary.json"
}

# ── Teardown ──

teardown() {
    if [[ ! -f "$STATE_DIR/nodes.json" ]]; then
        log "No state file found, nothing to tear down"
        return
    fi

    log "=== Tearing down infrastructure ==="

    # Stop servers gracefully
    for n in $(seq 0 $((NODE_COUNT - 1))); do
        local ip
        ip=$(node_ip "$n" 2>/dev/null || echo "")
        if [[ -n "$ip" && "$ip" != "null" ]]; then
            ssh_node "$n" "pkill -f 'zest serve'" 2>/dev/null || true
        fi
    done

    # Delete servers
    for n in $(seq 0 $((NODE_COUNT - 1))); do
        local name
        name=$(node_name "$n")
        if hcloud server describe "$name" &>/dev/null; then
            log "Deleting server $name..."
            hcloud server delete "$name" --poll-interval 2s || true
        fi
    done

    # Delete firewall
    if hcloud firewall describe "$FIREWALL_NAME" &>/dev/null; then
        log "Deleting firewall $FIREWALL_NAME..."
        hcloud firewall delete "$FIREWALL_NAME" || true
    fi

    # Delete SSH key from Hetzner
    if hcloud ssh-key describe "$SSH_KEY_NAME" &>/dev/null; then
        log "Deleting SSH key $SSH_KEY_NAME..."
        hcloud ssh-key delete "$SSH_KEY_NAME" || true
    fi

    # Remove local state (preserve results)
    rm -f "$STATE_DIR/nodes.json" "$STATE_DIR/ssh_key" "$STATE_DIR/ssh_key.pub"
    log "Teardown complete (results preserved in $RESULTS_DIR)"
}

# ── Status ──

status() {
    if [[ ! -f "$STATE_DIR/nodes.json" ]]; then
        log "No active test infrastructure"
        return
    fi

    log "Active nodes:"
    for n in $(seq 0 $((NODE_COUNT - 1))); do
        local ip name
        ip=$(node_ip "$n" 2>/dev/null || echo "unknown")
        name=$(node_name "$n")
        local reachable
        reachable=$(ssh_node "$n" "hostname" 2>/dev/null || echo "unreachable")
        log "  $name: $ip ($reachable)"
    done

    if [[ -f "$RESULTS_DIR/summary.json" ]]; then
        log ""
        log "Last test results:"
        jq . "$RESULTS_DIR/summary.json" 2>/dev/null || true
    fi
}

# ── Usage ──

usage() {
    cat <<EOF
zest P2P Integration Test (Hetzner Cloud)

Usage: $0 <command>

Commands:
  all        Full lifecycle: provision, deploy, test, report, teardown
  provision  Create 3 CX22 instances + firewall
  deploy     Cross-compile zest and deploy to all nodes
  test       Run CDN baseline + P2P download tests
  report     Print results summary
  teardown   Destroy all Hetzner resources
  status     Show current node state

Environment:
  HCLOUD_TOKEN   Hetzner Cloud API token (required)
  HF_TOKEN       HuggingFace API token (required)

Cost: ~EUR 0.05 for a full test run (~10 min at EUR 0.0066/hr per node)
EOF
}

# ── Main ──

case "${1:-help}" in
    all)
        check_deps
        provision
        deploy
        test_all
        teardown
        ;;
    provision)  check_deps; provision ;;
    deploy)     check_deps; deploy ;;
    test)       check_deps; test_all ;;
    report)     report ;;
    teardown)   teardown ;;
    status)     status ;;
    help|*)     usage ;;
esac

#!/usr/bin/env bash
# ─── External Workflow Monitor for Gayroxy ────────────────────────────────
# Runs OUTSIDE GitHub Actions (cron, local machine, or separate runner).
# Detects stuck runs (queued/in_progress > 2 min), force-cancels, re-triggers,
# and verifies the new run establishes the tunnel.
#
# Usage: .github/monitor-workflow.sh [--once] [--interval 60]
#   --once       Run a single check and exit (good for cron)
#   --interval N Check every N seconds (default 60, daemon mode)
#
# Requires: gh CLI authenticated with repo access, jq

set -euo pipefail

# Config
REPO="lawbr3aker-a97821387/gayroxy"
WF_NAME="Build & Deploy Proxy"
REF="master"
STUCK_THRESHOLD=120       # seconds before a run is "stuck" (2 min)
BOOT_VERIFY_TIMEOUT=180   # seconds to wait for new run to boot (3 min)
CHECK_INTERVAL=60         # seconds between checks (daemon mode)
MAX_RETRIES=3             # max force-cancel + re-trigger cycles per check
FORCE_CANCEL_API_VERSION="2022-11-28"

# Colors
RED='\033[0;31m'; GRN='\033[0;32m'; YEL='\033[1;33m'; BLU='\033[0;34m'; NC='\033[0m'
log()   { echo -e "${BLU}[$(date +'%H:%M:%S')]${NC} $*"; }
ok()    { echo -e "${GRN}[$(date +'%H:%M:%S')] ✔${NC} $*"; }
warn()  { echo -e "${YEL}[$(date +'%H:%M:%S')] ⚠${NC} $*"; }
error() { echo -e "${RED}[$(date +'%H:%M:%S')] ✖${NC} $*"; }

# Parse args
MODE="daemon"
while [[ $# -gt 0 ]]; do
    case $1 in
        --once) MODE="once"; shift ;;
        --interval) CHECK_INTERVAL="$2"; shift 2 ;;
        *) error "Unknown arg: $1"; exit 1 ;;
    esac
done

# Check prerequisites
for cmd in gh jq curl; do
    if ! command -v "$cmd" &>/dev/null; then
        error "Missing dependency: $cmd"
        exit 1
    fi
done

# Check gh auth (use --active to avoid non-active account errors)
if ! gh auth status --active &>/dev/null; then
    error "gh not authenticated. Run: gh auth login"
    exit 1
fi

# Get tunnel domain from latest successful run or env
get_tunnel_domain() {
    # Try to get from latest completed run's logs or use known pattern
    # The tunnel domain is deterministic: gaaayroxy.ai-masters.ir
    echo "gaaayroxy.ai-masters.ir"
}

TUNNEL_DOMAIN=$(get_tunnel_domain)

# ─── Core Functions ────────────────────────────────────────────────────────

# Get all non-completed runs for the workflow
get_active_runs() {
    gh api "repos/$REPO/actions/runs" \
        --jq ".workflow_runs[] | select(.path==\".github/workflows/main.yml\" and .head_branch==\"$REF\" and .status!=\"completed\") | {id: .id, status: .status, created: .created_at, html_url: .html_url}" \
        2>/dev/null
}

# Get run details
get_run_info() {
    local run_id="$1"
    gh api "repos/$REPO/actions/runs/$run_id" \
        --jq '{status: .status, conclusion: .conclusion, created: .created_at, updated: .updated_at, html_url: .html_url}' \
        2>/dev/null
}

# Get run duration in seconds
get_run_age() {
    local created="$1"
    local now=$(date -u +%s)
    local created_epoch=$(date -u -d "$created" +%s 2>/dev/null || date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$created" +%s 2>/dev/null)
    echo $((now - created_epoch))
}

# Force-cancel a run via API (the method you provided)
force_cancel_run() {
    local run_id="$1"
    log "Force-cancelling run #$run_id via GitHub API..."
    local resp
    resp=$(gh api --method POST \
        -H "Accept: application/vnd.github+json" \
        -H "X-GitHub-Api-Version: $FORCE_CANCEL_API_VERSION" \
        "/repos/$REPO/actions/runs/$run_id/force-cancel" 2>&1)
    local rc=$?
    if [[ $rc -eq 0 ]]; then
        ok "Force-cancelled run #$run_id"
        return 0
    else
        # 409 = already completed/cancelled, 404 = not found
        if echo "$resp" | grep -q "409\|already\|completed"; then
            warn "Run #$run_id already terminal (409/404)"
            return 0
        fi
        error "Force-cancel failed for #$run_id: $resp"
        return 1
    fi
}

# Trigger a new workflow run
trigger_new_run() {
    log "Dispatching new workflow run..."
    if gh workflow run "$WF_NAME" --ref "$REF" --repo "$REPO" 2>&1; then
        ok "New run dispatched"
        return 0
    else
        error "Failed to dispatch new run"
        return 1
    fi
}

# Wait for a new run to appear and get its ID
wait_for_new_run() {
    local before_time="$1"  # ISO timestamp before dispatch
    local timeout=60
    local start=$(date +%s)
    
    while (( $(date +%s) - start < timeout )); do
        local runs
        runs=$(gh api "repos/$REPO/actions/runs" \
            --jq ".workflow_runs[] | select(.path==\".github/workflows/main.yml\" and .head_branch==\"$REF\" and .created_at > \"$before_time\") | {id: .id, status: .status}" 2>/dev/null | head -1)
        if [[ -n "$runs" ]]; then
            local run_id=$(echo "$runs" | jq -r '.id')
            local status=$(echo "$runs" | jq -r '.status')
            echo "$run_id $status"
            return 0
        fi
        sleep 3
    done
    error "Timeout waiting for new run to appear"
    return 1
}

# Verify tunnel is established (public endpoint responds)
verify_tunnel_established() {
    local run_id="$1"
    local timeout="$BOOT_VERIFY_TIMEOUT"
    local start=$(date +%s)
    local endpoint="https://${TUNNEL_DOMAIN}/sub"
    
    log "Verifying tunnel establishment for run #$run_id (up to ${timeout}s)..."
    
    while (( $(date +%s) - start < timeout )); do
        # Check run status first
        local run_info
        run_info=$(get_run_info "$run_id")
        local status=$(echo "$run_info" | jq -r '.status')
        local conclusion=$(echo "$run_info" | jq -r '.conclusion // ""')
        
        if [[ "$status" == "completed" ]]; then
            if [[ "$conclusion" == "success" ]]; then
                ok "Run #$run_id completed successfully"
            else
                error "Run #$run_id failed: $conclusion"
                return 1
            fi
        elif [[ "$status" == "in_progress" ]]; then
            # Try the public endpoint
            if curl -sf -o /dev/null --max-time 10 "$endpoint" 2>/dev/null; then
                ok "Tunnel endpoint $endpoint responds (run #$run_id)"
                return 0
            fi
        fi
        
        sleep 5
    done
    
    error "Tunnel verification timeout for run #$run_id (${timeout}s)"
    return 1
}

# Check if any run is stuck
check_stuck_runs() {
    local runs_json
    runs_json=$(get_active_runs)
    
    if [[ -z "$runs_json" ]]; then
        log "No active runs found" >&2
        return 0
    fi
    
    local stuck_count=0
    local now=$(date +%s)
    
    echo "$runs_json" | while IFS= read -r run; do
        [[ -z "$run" ]] && continue
        local run_id=$(echo "$run" | jq -r '.id')
        local status=$(echo "$run" | jq -r '.status')
        local created=$(echo "$run" | jq -r '.created')
        local age=$(get_run_age "$created")
        
        if [[ "$status" == "queued" || "$status" == "in_progress" ]]; then
            if (( age > STUCK_THRESHOLD )); then
                warn "Run #$run_id stuck in '$status' for ${age}s (>${STUCK_THRESHOLD}s threshold)" >&2
                echo "$run_id"
                stuck_count=$((stuck_count + 1))
            else
                ok "Run #$run_id in '$status' for ${age}s (OK)" >&2
            fi
        fi
    done
}

# Handle a single stuck run
handle_stuck_run() {
    local run_id="$1"
    local retry=0
    
    while (( retry < MAX_RETRIES )); do
        log "Handling stuck run #$run_id (attempt $((retry+1))/$MAX_RETRIES)"
        
        # 1. Force-cancel
        if ! force_cancel_run "$run_id"; then
            error "Failed to cancel, will retry"
            ((retry++))
            sleep 10
            continue
        fi
        
        # 2. Wait a moment for cancellation to settle
        sleep 5
        
        # 3. Trigger new run
        local before_time=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
        if ! trigger_new_run; then
            error "Failed to trigger new run"
            ((retry++))
            sleep 10
            continue
        fi
        
        # 4. Wait for new run to appear
        local new_run_info
        if ! new_run_info=$(wait_for_new_run "$before_time"); then
            error "New run didn't appear"
            ((retry++))
            sleep 10
            continue
        fi
        
        local new_run_id=$(echo "$new_run_info" | awk '{print $1}')
        log "New run #$new_run_id appeared"
        
        # 5. Verify tunnel establishment
        if verify_tunnel_established "$new_run_id"; then
            ok "Successfully recovered: run #$new_run_id tunnel established"
            return 0
        else
            error "New run #$new_run_id failed verification"
            # The failed run will be caught in next check cycle
            return 1
        fi
    done
    
    error "Max retries exceeded for run #$run_id"
    return 1
}

# ─── Main Loop ─────────────────────────────────────────────────────────────

main() {
    log "Starting workflow monitor for $REPO/$WF_NAME"
    log "Stuck threshold: ${STUCK_THRESHOLD}s, Boot verify: ${BOOT_VERIFY_TIMEOUT}s"
    
    if [[ "$MODE" == "once" ]]; then
        log "Single check mode"
        local stuck_runs
        stuck_runs=$(check_stuck_runs)
        if [[ -n "$stuck_runs" ]]; then
            echo "$stuck_runs" | while IFS= read -r run_id; do
                [[ -n "$run_id" ]] && handle_stuck_run "$run_id"
            done
        else
            ok "No stuck runs detected"
        fi
    else
        log "Daemon mode: checking every ${CHECK_INTERVAL}s (Ctrl-C to stop)"
        while true; do
            local stuck_runs
            stuck_runs=$(check_stuck_runs)
            if [[ -n "$stuck_runs" ]]; then
                echo "$stuck_runs" | while IFS= read -r run_id; do
                    [[ -n "$run_id" ]] && handle_stuck_run "$run_id"
                done
            fi
            sleep "$CHECK_INTERVAL"
        done
    fi
}

# Run
main "$@"
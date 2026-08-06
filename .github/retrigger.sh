#!/usr/bin/env bash
# ─── Re-trigger script for Gayroxy workflow ──────────────────────────────
# Called by GitHub Actions to trigger the next run with a random commit.
set -euo pipefail

# Tunnel liveness check — same logic as proxy.sh: probe /sub (nginx endpoint),
# -f (fail on 4xx/5xx) so Cloudflare error pages count as DOWN.
tunnel_alive() {
    curl -sf -o /dev/null --max-time 8 "https://${CF_DOMAIN}/sub" 2>/dev/null
}

# If a tunnel is already live (handover in progress / another run took over),
# do NOT dispatch another run — that would snowball redundant runs. The live
# run's own AUTO_RETRIGGER will spawn the successor before it times out.
if tunnel_alive; then
    echo "Tunnel already live — skipping re-trigger (handover in progress)."
    exit 0
fi

DELAY=$(( RANDOM % 45 + 15 ))
echo "Waiting ${DELAY}s before re-triggering..."
sleep "$DELAY"

echo "::group::Dispatching next run..."

# ── Create a random commit to trigger via push (looks more natural) ──
TIMESTAMP_FILE=".github/last-run.txt"
mkdir -p .github

python3 << 'PYEOF'
import os, subprocess, random, string
ts = ".github/last-run.txt"
run_id = os.environ.get('GITHUB_RUN_ID', '?')
random_str = ''.join(random.choices(string.ascii_lowercase + string.digits, k=16))
import datetime
ts_iso = datetime.datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%SZ")
content = f"""Last run: {ts_iso}
Run ID: {run_id}
Random: {random_str}
"""
with open(ts, 'w') as f:
    f.write(content)

subprocess.run(['git', 'config', 'user.name', 'github-actions[bot]'], capture_output=True)
subprocess.run(['git', 'config', 'user.email', '41898282+github-actions[bot]@users.noreply.github.com'], capture_output=True)
subprocess.run(['git', 'add', ts], capture_output=True)
r = subprocess.run(['git', 'commit', '-m', f'🔄 Auto-update [run:{run_id}]'], capture_output=True)
if r.returncode == 0:
    subprocess.run(['git', 'push'], capture_output=True)
    print(f"Pushed random commit (run:{run_id})")
else:
    print("Nothing to commit — will dispatch directly")
PYEOF

# ── Also dispatch workflow directly as backup ──
gh workflow run "${{ github.workflow }}" --ref "${{ github.ref }}" 2>/dev/null || true
echo "::endgroup::"

# ── Verify next run picked up ──
NEXT=$(gh run list --workflow "${{ github.workflow }}" --branch "${{ github.ref }}" \
  --json databaseId,status --jq \
  '.[] | select(.databaseId != ${{ github.run_id }} and .status != "completed") | "\(.databaseId)|\(.status)"' \
  | head -1)

if [[ -z "$NEXT" ]]; then
  echo "No new run — dispatching again..."
  gh workflow run "${{ github.workflow }}" --ref "${{ github.ref }}" 2>/dev/null || true
else
  ID="${NEXT%%|*}"
  STATUS="${NEXT##*|}"
  echo "Next run #$ID (status: $STATUS)"
  if [[ "$STATUS" == "queued" || "$STATUS" == "pending" || "$STATUS" == "waiting" ]]; then
    echo "Stuck — cancelling and re-dispatching..."
    gh run cancel "$ID" 2>/dev/null || true
    sleep 3
    gh workflow run "${{ github.workflow }}" --ref "${{ github.ref }}" 2>/dev/null || true
  fi
fi
echo "::endgroup::"
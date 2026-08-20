#!/usr/bin/env bash
# ─── Re-trigger script for Gayroxy workflow ──────────────────────────────
# Called by GitHub Actions (always(), incl. failure/timeout/cancel) to ensure
# the next run gets dispatched so the proxy chain never dies.
#
# SNOWBALL BRAKE: with concurrency:cancel-in-progress, a new run cancels the
# old one the instant it starts — and the old run's always() step still runs.
# A tunnel-liveness probe would find the new run's tunnel not yet booted and
# dispatch yet another run → ping-pong storm (exactly what happened before).
# So the guard is: "is any OTHER run already queued/in_progress?" If yes,
# skip — that run is the chain continuation. cancel-in-progress guarantees at
# most one in-progress run, so this check can never race into a storm.
set -euo pipefail

WF_NAME="${GITHUB_WORKFLOW:-Build & Deploy Proxy}"
REF="${GITHUB_REF_NAME:-master}"

# If a successor run already exists, do NOT dispatch another — the running
# chain will handle it.
existing=$(gh run list --branch "$REF" \
  --json databaseId,status,workflowName --jq \
  '.[] | select(.databaseId != '"$GITHUB_RUN_ID"' and .workflowName == "Build & Deploy Proxy" and .status != "completed") | .databaseId' \
  2>/dev/null | head -1 || true)
if [[ -n "$existing" ]]; then
  echo "Successor run #$existing already queued/in-progress — skipping re-trigger."
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
PYEOF

echo "::endgroup::"

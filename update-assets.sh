#!/usr/bin/env bash
# ─── update-assets.sh — laptop / manual update ───────────────────────────────
# Re-render the assets locally (RENDER_ONLY — no xray/nginx/tunnel needed) and
# push them to the Cloudflare Worker + KV in one shot. Use the SAME SEED as CI
# (defaults to your CF_TOKEN) so credentials stay deterministic across runs —
# if you change the seed, every client's configs change.
#
# Usage:
#   CF_TOKEN=xxx ./update-assets.sh
#   CF_TOKEN=xxx SEED=my-secret ./update-assets.sh
#   CF_TOKEN=xxx WORKER_ROUTE=sub.example.com ./update-assets.sh   # + custom domain
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

export RENDER_ONLY=1
export SEED="${SEED:-${CF_TOKEN:-gayroxy}}"

echo "── Rendering assets (RENDER_ONLY, seed locked) ──"
./proxy.sh

echo "── Deploying to Cloudflare Worker + KV ──"
./deploy-cf.sh

echo "✅ Done. Panel/sub/geo are live on the Worker URL printed above."

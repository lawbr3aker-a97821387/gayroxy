#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────────────
# publish-live.sh  —  Push rendered assets to Cloudflare Worker + KV (LIVE_DEPLOY)
#
# Separate job downloads the build-assets artifact (sub/*) and deploys it so the
# Worker's KV serves sub.txt/panel/geo at WORKER_URL. Sources common.sh purely to
# adopt the SAME derived API_TOKEN → matches the Worker's binding (security fix
# from ca100b8) and the health agent's push auth.
# ──────────────────────────────────────────────────────────────────────────────
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "${SCRIPT_DIR}/scripts/lib/common.sh"

# deploy-cf.sh is standalone (own log/warn, does NOT source common.sh). It reads
# SUB_DIR, CF_TOKEN, WORKER_DOMAIN, and API_TOKEN from the environment.
export CF_TOKEN WORKER_DOMAIN API_TOKEN
# Ensure SUB_DIR points at the downloaded artifact (workflow sets this), else the
# repo's sub/ as a fallback.
SUB_DIR="${SUB_DIR:-${SCRIPT_DIR}/sub}"
export SUB_DIR

log "publish-live: deploying rendered assets from ${SUB_DIR} to Cloudflare (Worker: ${WORKER_DOMAIN:-<workers.dev>})..."

if [[ -z "${CF_TOKEN:-}" ]]; then
    warn "publish-live: CF_TOKEN missing — skipping Cloudflare push."
    exit 1
fi

if [[ ! -d "$SUB_DIR" ]]; then
    error "publish-live: ${SUB_DIR} not found — download the build-assets artifact first."
    exit 1
fi

if "${SCRIPT_DIR}/deploy-cf.sh"; then
    DOMAIN="${DOMAIN:-${WORKER_DOMAIN:-${WORKER_URL#https://}}}"
    log "publish-live: ✔ live assets published: sub.txt now points at https://${DOMAIN}"
else
    error "publish-live: deploy-cf.sh failed — live URL not published (see logs above)."
    exit 1
fi

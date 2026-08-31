#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────────────
# boot-verify.sh  —  Public endpoint probe
#
# Runs in its own GitHub Actions job AFTER deploy-assets, verifying the Cloudflare
# Worker serves the freshly-deployed sub end-to-end. Probes https://DOMAIN/sub
# from outside (different runner) within BOOT_VERIFY_TIMEOUT. DOMAIN here is the
# public Worker host (WORKER_DOMAIN if set, else the WORKER_URL host) — not the
# tunnel host (serve verifies that separately).
# Non-zero exit marks the job failed; serve (if: always()) still boots.
# ──────────────────────────────────────────────────────────────────────────────
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "${SCRIPT_DIR}/scripts/lib/common.sh"

# Canonical public Worker host: custom WORKER_DOMAIN → its host, else WORKER_URL host.
if [[ -n "${WORKER_DOMAIN:-}" ]]; then
    DOMAIN="${WORKER_DOMAIN}"
elif [[ -n "${WORKER_URL:-}" ]]; then
    DOMAIN="${WORKER_URL#https://}"
    DOMAIN="${WORKER_URL#http://}"
else
    # Last resort: same derivation as every other phase (named tunnel host).
    source "${SCRIPT_DIR}/scripts/lib/cloudflare.sh"
    resolve_domain
fi
export DOMAIN

BOOT_VERIFY_TIMEOUT="${BOOT_VERIFY_TIMEOUT:-180}"   # seconds total
SLEEP_SEC=10

log "boot-verify: checking https://${DOMAIN}/sub (up to ${BOOT_VERIFY_TIMEOUT}s)..."

boot_ok=0
for ((i=1; i<=BOOT_VERIFY_TIMEOUT/SLEEP_SEC; i++)); do
    if curl -sf -o /dev/null --max-time "$SLEEP_SEC" "https://${DOMAIN}/sub" 2>/dev/null; then
        boot_ok=1
        log "boot-verify: ✔ public endpoint responds (attempt ${i})"
        break
    fi
    warn "boot-verify: not ready (attempt ${i}/$((BOOT_VERIFY_TIMEOUT/SLEEP_SEC))) — retrying..."
    sleep "$SLEEP_SEC"
done

if [[ "$boot_ok" != "1" ]]; then
    error "boot-verify: public endpoint unreachable within ${BOOT_VERIFY_TIMEOUT}s — exiting."
    exit 1
fi

log "boot-verify: ✔ endpoint verified."

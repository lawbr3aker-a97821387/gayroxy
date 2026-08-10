#!/usr/bin/env bash
# ─── deploy-cf.sh ─────────────────────────────────────────────────────────────
# Deploy Gayroxy static assets to Cloudflare Workers + KV — the always-on
# replacement for GitHub Pages. Runs on every workflow deploy AND locally
# (laptop script). Self-bootstrapping: needs ONLY CF_TOKEN — the account ID is
# discovered from the token, the KV namespace is created if missing, assets are
# uploaded, and the Worker script is published.
#
# Usage:
#   CF_TOKEN=xxx ./deploy-cf.sh                         # deploy everything
#   CF_TOKEN=xxx ./deploy-cf.sh --print-url             # just print the worker URL
#   CF_TOKEN=xxx WORKER_ROUTE=sub.example.com ./deploy-cf.sh  # + custom domain route
#
# CF_TOKEN permissions (Cloudflare dashboard → My Profile → API Tokens → Create):
#   Account · Workers Scripts:Edit        (upload the Worker)
#   Account · Workers KV Storage:Edit     (write KV values)
#   Account · Account Settings:Read       (discover account ID + workers.dev subdomain)
#   Zone    · Workers Routes:Edit         (ONLY if you use WORKER_ROUTE)
#
# After a successful deploy it also stores the live URL as the GitHub repo
# variable WORKER_URL (best-effort, when gh is authenticated) so downstream
# runs know where the assets live without any manual setup.
# ───────────────────────────────────────────────────────────────────────────────
set -euo pipefail

SCRIPT_NAME="gayroxy"
KV_NAMESPACE_TITLE="gayroxy-assets"
API="https://api.cloudflare.com/client/v4"
WORKDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

CF_TOKEN="${CF_TOKEN:-}"
if [[ -z "$CF_TOKEN" ]]; then
    echo "ERROR: CF_TOKEN is not set." >&2
    echo "Create one (Workers Scripts:Edit + Workers KV Storage:Edit + Account Settings:Read) then:" >&2
    echo "  gh secret set CF_TOKEN    # for CI" >&2
    exit 1
fi

# ─── API helper: prints result JSON on success, exits with the API error ─────
api() {
    local method="$1" path="$2"
    shift 2
    local resp
    resp=$(curl -sS -X "$method" -H "Authorization: Bearer ${CF_TOKEN}" "$@" "${API}${path}") \
        || { echo "ERROR: curl failed on ${method} ${path}" >&2; exit 1; }
    echo "$resp" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    print("ERROR: invalid Cloudflare API response:", file=sys.stderr)
    sys.exit(1)
if not d.get("success"):
    errs = d.get("errors", []) or [{}]
    msgs = "; ".join(e.get("message", "?") for e in errs)
    code = errs[0].get("code", "?")
    print("ERROR: Cloudflare API ({}): {}".format(code, msgs), file=sys.stderr)
    sys.exit(1)
print(json.dumps(d.get("result")))
'
}

log() { echo -e "\033[0;32m[deploy-cf]\033[0m $1"; }
warn() { echo -e "\033[1;33m[deploy-cf] WARNING\033[0m $1"; }

# ─── 1. Discover account ID from the token ───────────────────────────────────
ACCOUNTS=$(api GET "/accounts?per_page=50")
ACCOUNT_ID=$(echo "$ACCOUNTS" | python3 -c 'import json,sys; r=json.load(sys.stdin); print(r[0]["id"] if r else "")')
if [[ -z "$ACCOUNT_ID" ]]; then
    echo "ERROR: CF_TOKEN has no account access — it must be scoped to at least one account." >&2
    exit 1
fi
log "Account: ${ACCOUNT_ID}"

# ─── 2. Find-or-create the KV namespace ──────────────────────────────────────
NS_LIST=$(api GET "/accounts/${ACCOUNT_ID}/storage/kv/namespaces?per_page=100")
NS_ID=$(echo "$NS_LIST" | python3 -c '
import json, sys
title = "'"${KV_NAMESPACE_TITLE}"'"
r = json.load(sys.stdin)
print(next((n["id"] for n in r if n.get("title") == title), ""))
')
if [[ -z "$NS_ID" ]]; then
    log "Creating KV namespace '${KV_NAMESPACE_TITLE}'..."
    NS_ID=$(api POST "/accounts/${ACCOUNT_ID}/storage/kv/namespaces" \
        --data "{\"title\":\"${KV_NAMESPACE_TITLE}\"}" \
        | python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])')
fi
log "KV namespace: ${NS_ID}"

# ─── 3. Upload assets to KV ──────────────────────────────────────────────────
# Map: local path → KV key. /sub and /sub.txt are aliases of the same file;
# the Worker also aliases /sub → sub.txt, but we store both names so any
# host/proxy that serves KV directly (e.g. a CDN in front) works too.
put_value() { # local_file kv_key
    local file="$1" key="$2"
    [[ -f "$file" ]] || { warn "missing asset (skipping): $file"; return 0; }
    local enc
    enc=$(python3 -c 'import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1], safe=""))' "$key")
    # shellcheck disable=SC2155
    local out
    out=$(api PUT "/accounts/${ACCOUNT_ID}/storage/kv/namespaces/${NS_ID}/values/${enc}" \
        --data-binary "@${file}") || return 1
    log "KV: ${key} ← $(basename "$file") ($(du -h "$file" | cut -f1))"
}

SUB_DIR="${WORKDIR}/sub"
GEO_DIR="${WORKDIR}/geo"
if [[ ! -d "$SUB_DIR" ]]; then
    echo "ERROR: ${SUB_DIR} not found — run ./proxy.sh (RENDER_ONLY=1) first, or use ./update-assets.sh." >&2
    exit 1
fi

put_value "${SUB_DIR}/index.html"        "index.html"
put_value "${SUB_DIR}/panel.html"        "panel.html"
put_value "${SUB_DIR}/subscription.b64"  "subscription.b64"
put_value "${SUB_DIR}/subscription.b64"  "sub.txt"
if [[ -d "$GEO_DIR" ]]; then
    for f in "$GEO_DIR"/*; do
        [[ -f "$f" ]] || continue
        put_value "$f" "geo/$(basename "$f")"
    done
else
    warn "geo/ not found — geo databases not updated (existing KV values stay live)."
fi

# ─── 4. Upload the Worker script (module format, KV binding) ─────────────────
log "Uploading Worker '${SCRIPT_NAME}'..."
METADATA="{\"main_module\":\"index.js\",\"compatibility_date\":\"2024-11-01\",\"bindings\":[{\"name\":\"ASSETS\",\"type\":\"kv_namespace\",\"namespace_id\":\"${NS_ID}\"}]}"
api PUT "/accounts/${ACCOUNT_ID}/workers/scripts/${SCRIPT_NAME}" \
    -F "metadata=${METADATA};type=application/json" \
    -F "index.js=@${WORKDIR}/worker/index.js;type=application/javascript" >/dev/null
log "Worker deployed."

# ─── 5. Print the live URL ───────────────────────────────────────────────────
SUBDOMAIN=$(api GET "/accounts/${ACCOUNT_ID}/workers/subdomain" \
    | python3 -c 'import json,sys; print(json.load(sys.stdin).get("subdomain",""))')
URL=""
if [[ -n "$SUBDOMAIN" ]]; then
    URL="https://${SCRIPT_NAME}.${SUBDOMAIN}.workers.dev"
    log "Worker URL: ${URL}"
else
    warn "Account has no workers.dev subdomain enabled — enable it in the Cloudflare"
    warn "dashboard (Workers & Pages → your subdomain) or set WORKER_ROUTE."
fi

# Optional custom-domain route: WORKER_ROUTE=sub.example.com
if [[ -n "${WORKER_ROUTE:-}" ]]; then
    ZONE_NAME="${WORKER_ROUTE#*.}"   # strip the first label
    ZONES=$(api GET "/zones?name=${ZONE_NAME}&per_page=5")
    ZONE_ID=$(echo "$ZONES" | python3 -c 'import json,sys; r=json.load(sys.stdin); print(r[0]["id"] if r else "")')
    if [[ -z "$ZONE_ID" ]]; then
        warn "Zone '${ZONE_NAME}' not found on this token — custom route skipped."
        warn "(The zone must be on Cloudflare and the token needs Zone:Read + Workers Routes:Edit.)"
    else
        api POST "/zones/${ZONE_ID}/workers/routes" \
            --data "{\"pattern\":\"${WORKER_ROUTE}/*\",\"script\":\"${SCRIPT_NAME}\"}" >/dev/null \
            && log "Route: ${WORKER_ROUTE}/* → ${SCRIPT_NAME}"
        URL="https://${WORKER_ROUTE}"
    fi
fi

# ─── 6. Persist WORKER_URL as a repo variable (best-effort, CI or laptop) ────
if [[ -n "$URL" ]] && command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
    gh variable set WORKER_URL --body "$URL" >/dev/null 2>&1 \
        && log "Saved WORKER_URL repo variable: ${URL}" \
        || warn "Could not save WORKER_URL repo variable (gh auth missing?) — set it manually if needed."
fi

[[ -n "$URL" ]] && echo "DEPLOYED_URL=${URL}"
echo "✅ Deploy complete."

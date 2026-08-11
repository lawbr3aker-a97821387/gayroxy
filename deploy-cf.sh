#!/usr/bin/env bash
# ─── deploy-cf.sh ─────────────────────────────────────────────────────────────
# Deploy Gayroxy static assets to Cloudflare Workers + KV — the always-on
# replacement for GitHub Pages. Runs on every workflow deploy AND locally
# (laptop script). Self-bootstrapping: needs ONLY CF_TOKEN — the account ID is
# discovered from the token, the KV namespace is created if missing, assets are
# uploaded, and the Worker script is published.
#
# Usage:
#   CF_TOKEN=xxx ./deploy-cf.sh                                   # deploy everything
#   CF_TOKEN=xxx ./deploy-cf.sh --print-url                        # just print the worker URL
#   CF_TOKEN=xxx WORKER_DOMAIN=gayroxy-cf.ai-masters.ir ./deploy-cf.sh  # + custom domain
#   CF_TOKEN=xxx WORKER_ROUTE=gayroxy.example.com ./deploy-cf.sh   # + legacy route (fallback)
#
# WORKER_DOMAIN (recommended): creates a Workers Custom Domain — a dedicated
# hostname with automatic DNS + managed TLS certificate. Requires the zone to
# be active on Cloudflare, and the token to have:
#   Account · Workers Scripts:Edit        (upload the Worker)
#   Account · Workers KV Storage:Edit     (write KV values)
#   Account · Account Settings:Read       (discover account ID + workers.dev subdomain)
#   Zone    · Workers Routes:Edit         (bind the custom domain)
#   Zone    · DNS:Edit                     (auto-create the DNS record)
#
# CF_TOKEN permissions (Cloudflare dashboard → My Profile → API Tokens → Create
# via "Create Custom Token"):
#   Account · Workers Scripts:Edit        (upload the Worker)
#   Account · Workers KV Storage:Edit     (write KV values)
#   Account · Account Settings:Read       (discover account ID + workers.dev subdomain)
#   Zone    · Workers Routes:Edit         (bind WORKER_DOMAIN or WORKER_ROUTE)
#   Zone    · DNS:Edit                     (auto-create DNS record for WORKER_DOMAIN)
#   Zone    · Zone:Read                    (find the zone ID for your domain)
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
    local resp hdr=()
    # JSON bodies (--data) must declare application/json or Cloudflare rejects
    # them with error 10010; --data-binary file uploads and -F multipart are
    # sent as-is (their own Content-Type applies).
    for a in "$@"; do
        if [[ "$a" == "--data" ]]; then hdr=(-H "Content-Type: application/json"); break; fi
    done
    resp=$(curl -sS -X "$method" -H "Authorization: Bearer ${CF_TOKEN}" "${hdr[@]}" "$@" "${API}${path}") \
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

# ─── KV content-hash skip (S4b) ─────────────────────────────────────────────
# Before uploading, compare each local file's md5 against the metadata stored
# on the remote KV key (set on PUT below). Unchanged files are skipped — with
# the named tunnel the sub/panel/geo render identically every run, so only the
# first deploy of a cycle actually uploads. Saves ~150MB of geo uploads plus
# API calls per run.
KV_MD5_MAP=""   # "key<TAB>md5" lines, built from the KV key list
kv_load_hashes() {
    local list
    list=$(api GET "/accounts/${ACCOUNT_ID}/storage/kv/namespaces/${NS_ID}/keys?limit=1000") || return 0
    KV_MD5_MAP=$(echo "$list" | python3 -c '
import json, sys
try:
    r = json.load(sys.stdin)
except Exception:
    sys.exit(0)
for k in (r or []):
    md5 = (k.get("metadata") or {}).get("md5", "")
    if md5:
        name = k.get("name", "")
        print(name + "\t" + md5)
')
}
kv_remote_md5() {  # key → echo remote md5 (empty if unknown)
    local key="$1"
    echo "$KV_MD5_MAP" | awk -F'\t' -v k="$key" '$1 == k {print $2; exit}'
}

# ─── 3. Upload assets to KV ──────────────────────────────────────────────────
# Map: local path → KV key. /sub and /sub.txt are aliases of the same file;
# the Worker also aliases /sub → sub.txt, but we store both names so any
# host/proxy that serves KV directly (e.g. a CDN in front) works too.
put_value() { # local_file kv_key
    local file="$1" key="$2"
    [[ -f "$file" ]] || { warn "missing asset (skipping): $file"; return 0; }
    local md5 remote enc meta out
    md5=$(md5sum "$file" | awk '{print $1}')
    remote=$(kv_remote_md5 "$key")
    if [[ -n "$remote" && "$remote" == "$md5" ]]; then
        log "KV: ${key} unchanged (md5 ${md5:0:8}) — skip upload"
        return 0
    fi
    enc=$(python3 -c 'import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1], safe=""))' "$key")
    # Store the md5 as KV metadata so the next run can skip unchanged uploads.
    meta=$(python3 -c 'import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1], safe=""))' "{\"md5\":\"${md5}\"}")
    # shellcheck disable=SC2155
    out=$(api PUT "/accounts/${ACCOUNT_ID}/storage/kv/namespaces/${NS_ID}/values/${enc}?metadata=${meta}" \
        --data-binary "@${file}") || return 1
    log "KV: ${key} ← $(basename "$file") ($(du -h "$file" | cut -f1))"
}

SUB_DIR="${WORKDIR}/sub"
GEO_DIR="${WORKDIR}/geo"
if [[ ! -d "$SUB_DIR" ]]; then
    echo "ERROR: ${SUB_DIR} not found — run ./proxy.sh (RENDER_ONLY=1) first, or use ./update-assets.sh." >&2
    exit 1
fi

# Load remote md5 map once — every put_value below consults it for skip logic.
kv_load_hashes

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
    -F "index.js=@${WORKDIR}/worker/index.js;type=application/javascript+module" >/dev/null
log "Worker deployed."

# ─── 4b. Enable the workers.dev subdomain route for this script ────────────
# A freshly-uploaded Worker is NOT reachable on <script>.<sub>.workers.dev
# by default — the script/subdomain route is disabled, and every request 1042s
# with "error code: 1042" until it's turned on. Enable it explicitly here.
# Non-fatal: api() exits on failure, so run in a subshell; a failure here
# (already enabled, transient API error) must NOT abort an otherwise-good deploy.
if ( api POST "/accounts/${ACCOUNT_ID}/workers/scripts/${SCRIPT_NAME}/subdomain" \
        --data '{"enabled":true}' >/dev/null ); then
    log "workers.dev route enabled."
else
    warn "Could not enable workers.dev route (may already be on, or API error).
          If 1042s persist, toggle it in the dashboard and re-run."
fi

# ─── 5. Print the live URL ───────────────────────────────────────────────────
SUBDOMAIN=$(api GET "/accounts/${ACCOUNT_ID}/workers/subdomain" \
    | python3 -c 'import json,sys; print(json.load(sys.stdin).get("subdomain",""))')
URL=""
if [[ -n "$SUBDOMAIN" ]]; then
    URL="https://${SCRIPT_NAME}.${SUBDOMAIN}.workers.dev"
    log "Worker URL: ${URL}"
else
    warn "Account has no workers.dev subdomain enabled — enable it in the Cloudflare"
    warn "dashboard (Workers & Pages → your subdomain) or set WORKER_DOMAIN."
fi

# ─── 6. Optional custom domain (recommended): gayroxy-cf.ai-masters.ir ──────
# Creates a Workers Custom Domain — a dedicated hostname with automatic DNS +
# managed TLS certificate. This is the modern, recommended approach (works on
# the free plan). Falls back to a legacy Workers Route if the custom-domain
# API rejects the request (e.g. zone not on CF, or missing DNS:Edit permission).
#
# Env: WORKER_DOMAIN=gayroxy-cf.ai-masters.ir  (recommended)
#      WORKER_ROUTE=gayroxy.example.com        (legacy route fallback)
#      WORKER_DOMAIN takes precedence over WORKER_ROUTE.
if [[ -n "${WORKER_DOMAIN:-}" ]]; then
    ZONE_NAME="${WORKER_DOMAIN#*.}"   # strip the first label → ai-masters.ir
    ZONES=$(api GET "/zones?name=${ZONE_NAME}&per_page=5")
    ZONE_ID=$(echo "$ZONES" | python3 -c 'import json,sys; r=json.load(sys.stdin); print(r[0]["id"] if r else "")')
    if [[ -z "$ZONE_ID" ]]; then
        warn "Zone '${ZONE_NAME}' not found on this token — custom domain skipped."
        warn "Add the zone to your Cloudflare account (dashboard → Add a Site) and"
        warn "ensure the token has Zone:Read + Workers Routes:Edit + DNS:Edit."
    else
        log "Zone: ${ZONE_NAME} (${ZONE_ID})"

        # ── Custom Domain (recommended path) ──
        # POST /accounts/{account}/workers/domains
        # Body: { "environment": "production", "hostname": "...", "service": "gayroxy", "zone_id": "..." }
        # Idempotent: if the domain already exists, the API returns an error
        # — we detect that and proceed (it's already bound, no work needed).
        set +e
        DOMAIN_RESULT=$(api POST "/accounts/${ACCOUNT_ID}/workers/domains" \
            --data "{\"environment\":\"production\",\"hostname\":\"${WORKER_DOMAIN}\",\"service\":\"${SCRIPT_NAME}\",\"zone_id\":\"${ZONE_ID}\"}" 2>&1)
        API_RC=$?
        set -e

        if [[ $API_RC -eq 0 ]]; then
            log "Custom domain: https://${WORKER_DOMAIN} → ${SCRIPT_NAME} (auto-DNS + managed TLS)"
            URL="https://${WORKER_DOMAIN}"
        elif echo "$DOMAIN_RESULT" | grep -qiE "already exists|duplicate|1003"; then
            log "Custom domain already bound: https://${WORKER_DOMAIN} — reusing."
            URL="https://${WORKER_DOMAIN}"
        else
            # ── Fall back to legacy Workers Route ──
            warn "Custom-domain API rejected the request — falling back to legacy route."
            warn "Reason: $(echo "$DOMAIN_RESULT" | tail -1)"
            warn "(This usually means the zone is not fully active on Cloudflare, or the"
            warn " token is missing Zone:DNS Edit. The route method works too, but you'll"
            warn " need to create the DNS record manually in the dashboard.)"
            api POST "/zones/${ZONE_ID}/workers/routes" \
                --data "{\"pattern\":\"${WORKER_DOMAIN}/*\",\"script\":\"${SCRIPT_NAME}\"}" >/dev/null \
                && log "Route: ${WORKER_DOMAIN}/* → ${SCRIPT_NAME}" \
                && URL="https://${WORKER_DOMAIN}"
        fi
    fi

elif [[ -n "${WORKER_ROUTE:-}" ]]; then
    # Legacy: WORKER_ROUTE=gayroxy.example.com → creates a route pattern only.
    # You must create the DNS record yourself (CNAME to the worker or a dummy
    # A record → the route intercepts it). Use WORKER_DOMAIN instead if possible.
    ZONE_NAME="${WORKER_ROUTE#*.}"
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

# ─── 7. Persist WORKER_URL as a repo variable (best-effort, CI or laptop) ────
if [[ -n "$URL" ]] && command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
    gh variable set WORKER_URL --body "$URL" >/dev/null 2>&1 \
        && log "Saved WORKER_URL repo variable: ${URL}" \
        || warn "Could not save WORKER_URL repo variable (gh auth missing?) — set it manually if needed."
fi

[[ -n "$URL" ]] && echo "DEPLOYED_URL=${URL}"
echo "✅ Deploy complete."

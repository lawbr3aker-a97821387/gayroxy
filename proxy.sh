#!/usr/bin/env bash
set -euo pipefail

# ─── Configuration ───────────────────────────────────────────────────────────
XRAY_DIR="${PWD}"
XRAY_CONFIG_FILE="${XRAY_DIR}/config.json"
XRAY_BIN="${XRAY_DIR}/xray"
GEO_DIR="${XRAY_DIR}/geo"
NGINX_CONF="${XRAY_DIR}/nginx.conf"
SUB_DIR="${XRAY_DIR}/sub"
LOG_DIR="${XRAY_DIR}/logs"

# Ports (local only)
PORT_NGINX=9000
PORT_VLESS=10001
PORT_TROJAN=10002
PORT_VMESS=10003
PORT_VLESS_GRPC=10005
PORT_TROJAN_GRPC=10006
PORT_SHADOWSOCKS=10007
PORT_REALITY=10008
PORT_SOCKS5=10009
PORT_HTTP_PROXY=10010
PORT_SS_WS=10011
PORT_SS_GRPC=10012
PORT_VMESS_GRPC=10013
PORT_VLESS_HU=10014
PORT_TROJAN_HU=10015
PORT_VMESS_HU=10016
WARP_PORT=${WARP_PORT:-40000}

# Cloudflare variables — OPTIONAL. Two tunnel modes:
#   NAMED TUNNEL: CF_AUTHTOKEN + CF_DOMAIN set → custom domain
#                 (requires a Cloudflare account + a domain on it).
#   QUICK TUNNEL: neither set → free random trycloudflare.com URL,
#                 zero requirements (no account, no token, no domain).
CF_AUTHTOKEN="${CF_AUTHTOKEN:-}"
CF_DOMAIN="${CF_DOMAIN:-}"

# Cloudflare Worker URL for always-on static assets (sub/panel/geo served
# from Workers KV — the "Pages replacement"). e.g. https://gayroxy.<acct>.workers.dev
# Set by the workflow (repo variable WORKER_URL, written by deploy-cf.sh after
# the first deploy). Optional: when unset, the tunnel domain is the fallback and
# the quick-tunnel re-deploy step publishes the live URL a few minutes later.
# Trailing slash stripped so joins like ${WORKER_URL}/sub.txt don't double-slash.
WORKER_URL="${WORKER_URL:-${PAGES_URL:-${CF_DOMAIN:+https://${CF_DOMAIN}}}}"
WORKER_URL="${WORKER_URL%/}"

# Seed for deterministic credentials — same seed = same UUIDs/passwords every run
# (quick-tunnel mode has no CF token, so fall back to repo identity).
SEED="${SEED:-${CF_AUTHTOKEN:-${GITHUB_REPOSITORY:-gayroxy}}}"

# RENDER_ONLY=1: generate assets (sub/panel/geo) without starting any services.
# Used by CI to deploy Pages quickly; the long-lived tunnel runs in a later step.
RENDER_ONLY="${RENDER_ONLY:-0}"

# Reality TLS fronting target (stealth). Change if www.cloudflare.com is flagged;
# any major TLS site works. Must match in config.json, client URL and panel.
REALITY_SNI="${REALITY_SNI:-www.cloudflare.com}"

# Tunnel watchdog (medium #5): every WATCHDOG_INTERVAL seconds check the tunnel
# endpoint. After WATCHDOG_FAILS consecutive failures the run exits so the
# re-trigger cycle restarts the tunnel fast instead of waiting out the 240-min cap.
WATCHDOG_INTERVAL="${WATCHDOG_INTERVAL:-60}"
WATCHDOG_FAILS="${WATCHDOG_FAILS:-5}"

# Auto re-trigger (high #1): when set, proxy.sh spawns a background dispatcher
# that fires a fresh workflow run shortly before this run's timeout, so the next
# tunnel comes up ~immediately after this one dies (near-zero downtime).
# Uses GH_TOKEN (workflow_dispatch) — set to 1 in the proxy job.
AUTO_RETRIGGER="${AUTO_RETRIGGER:-0}"
RUN_TIMEOUT_MIN="${RUN_TIMEOUT_MIN:-240}"
RETRIGGER_LEAD_MIN="${RETRIGGER_LEAD_MIN:-8}"

# External subscriptions (optional). Set the EXTERNAL_SUB_URLS secret/env to a
# comma-separated list of subscription URLs to merge into the panel/sub. When
# unset, no external configs are merged (only the 15 built-in Gayroxy configs).
# Example: EXTERNAL_SUB_URLS="https://my-sub.example.com/sub,https://other.com/sub"
EXTERNAL_SUB_URLS="${EXTERNAL_SUB_URLS:-}"

# ─── Colors ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GRN='\033[0;32m'; YEL='\033[1;33m'; BLU='\033[0;34m'
CYAN='\033[0;36m'; MAG='\033[0;35m'; NC='\033[0m'
log()   { echo -e "${GRN}[proxy.sh]${NC} $1"; }
warn()  { echo -e "${YEL}[proxy.sh] WARNING${NC} $1"; }
error() { echo -e "${RED}[proxy.sh] ERROR${NC} $1"; }

help_msg() { cat <<'EOF'
Usage: CF_AUTHTOKEN=xxx CF_DOMAIN=proxy.example.com ./proxy.sh
EOF
}
for arg in "$@"; do case "$arg" in -h|--help) help_msg; exit 0;; esac; done

# ─── PID tracking + cleanup (registered early so any failure cleans up) ─────
XRAY_PID=""; CLOUDFLARED_PID=""
cleanup() {
    log "Stopping services..."
    [[ -f "${XRAY_DIR}/nginx.pid" ]] && nginx -c "${NGINX_CONF}" -s stop 2>/dev/null || true
    [[ -n "$CLOUDFLARED_PID" ]] && kill "$CLOUDFLARED_PID" 2>/dev/null || true
    [[ -n "$XRAY_PID" ]] && kill "$XRAY_PID" 2>/dev/null || true
    wait 2>/dev/null || true
    log "All services stopped."
}
trap cleanup INT TERM EXIT

# ─── Install dependencies ────────────────────────────────────────────────────
log "Checking dependencies..."
MISSING=()
# RENDER_ONLY doesn't need nginx (no local service is started)
if [[ "$RENDER_ONLY" == "1" ]]; then
    for pkg in curl unzip python3; do command -v "$pkg" &>/dev/null || MISSING+=("$pkg"); done
else
    for pkg in curl unzip python3 nginx; do command -v "$pkg" &>/dev/null || MISSING+=("$pkg"); done
fi
if [[ ${#MISSING[@]} -gt 0 ]]; then
    log "Installing: ${MISSING[*]}"
    if command -v apt-get &>/dev/null; then
        sudo apt-get update -qq && sudo apt-get install -y -qq "${MISSING[@]}"
    elif command -v apk &>/dev/null; then
        sudo apk add --no-cache "${MISSING[@]}"
    elif command -v dnf &>/dev/null; then
        sudo dnf install -y "${MISSING[@]}"
    else
        error "Cannot install: ${MISSING[*]}"; exit 1
    fi
fi

# ─── Install xray-core ──────────────────────────────────────────────────────
# (Skipped in RENDER_ONLY mode — assets don't need the binary)
if [[ "$RENDER_ONLY" != "1" && ! -x "$XRAY_BIN" ]]; then
    log "Downloading xray-core..."
    ARCH=$(uname -m)
    case "$ARCH" in
        x86_64)  XRAY_ZIP="Xray-linux-64.zip" ;;
        aarch64) XRAY_ZIP="Xray-linux-arm64-v8a.zip" ;;
        armv7l)  XRAY_ZIP="Xray-linux-arm32-v7a.zip" ;;
        *)       error "Unsupported arch: $ARCH"; exit 1 ;;
    esac
    URL=$(curl -sL https://api.github.com/repos/XTLS/Xray-core/releases/latest \
        | grep -oP '"browser_download_url"\s*:\s*"\K[^"]+' | grep "$XRAY_ZIP" | head -1)
    [[ -z "$URL" ]] && error "Could not find xray-core download." && exit 1
    curl -L --progress-bar -o xray.zip "$URL"
    unzip -o xray.zip xray >/dev/null 2>&1 || true
    chmod +x xray && rm -f xray.zip
    log "xray-core downloaded."
fi

# ─── Install Cloudflare tools (cloudflared + WARP) ──────────────────────────
# (Skipped in RENDER_ONLY mode — no tunnel is started)
if [[ "$RENDER_ONLY" == "1" ]]; then
    CLOUDFLARED_BIN="" WARP_BIN="" WARP_ACTIVE=false
else
    CLOUDFLARED_BIN=""
if command -v cloudflared &>/dev/null; then
    CLOUDFLARED_BIN=$(command -v cloudflared)
    log "Using system cloudflared"
fi

# cloudflared from pkg.cloudflare.com
if [[ -z "$CLOUDFLARED_BIN" ]]; then
    log "Installing cloudflared..."
    curl -fsSL https://pkg.cloudflare.com/cloudflare-main.gpg | sudo tee /usr/share/keyrings/cloudflare-main.gpg >/dev/null
    echo "deb [signed-by=/usr/share/keyrings/cloudflare-main.gpg] https://pkg.cloudflare.com/cloudflared any main" | sudo tee /etc/apt/sources.list.d/cloudflared.list
    sudo apt-get update && sudo apt-get install cloudflared
    CLOUDFLARED_BIN=$(command -v cloudflared)
    if [[ -z "${CLOUDFLARED_BIN}" ]]; then
        curl -L --progress-bar -o cloudflared "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-$(uname -m)"
        chmod +x cloudflared
        CLOUDFLARED_BIN="${PWD}/cloudflared"
    fi
    log "cloudflared installed."
fi

# WARP from pkg.cloudflareclient.com
WARP_ACTIVE=false
WARP_BIN=""

if command -v warp-cli &>/dev/null; then
    WARP_BIN=$(command -v warp-cli)
    log "Using system warp-cli"
else
    log "Installing Cloudflare WARP..."
    curl -fsSL https://pkg.cloudflareclient.com/pubkey.gpg | sudo gpg --yes --dearmor --output /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg \
        || warn "Failed to add WARP GPG key"
    echo "deb [signed-by=/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg] https://pkg.cloudflareclient.com/ $(lsb_release -cs) main" \
        | sudo tee /etc/apt/sources.list.d/cloudflare-client.list >/dev/null || true
    sudo apt-get update -qq && sudo apt-get install -y -qq cloudflare-warp 2>&1 | tail -3
    WARP_BIN=$(command -v warp-cli)
fi

if [[ -z "$WARP_BIN" ]]; then
    warn "warp-cli not found — skipping WARP (Reddit stealth unavailable)"
else
    # warp-svc is started by the package's postinst — just ensure D-Bus is up
    if ! pgrep -x dbus-daemon >/dev/null 2>&1; then
        sudo /etc/init.d/dbus start 2>/dev/null || sudo systemctl start dbus 2>/dev/null || true
        sleep 1
    fi

    # Wait for daemon socket to be ready
    for i in 1 2 3 4 5; do
        ss -xl 2>/dev/null | grep -q warp_service && break
        sleep 1
    done
    pgrep -x warp-svc >/dev/null 2>&1 || warn "warp-svc daemon not running"

    # Register (idempotent), set SOCKS5 proxy mode, connect
    sudo $WARP_BIN --accept-tos registration new 2>&1 || true
    sudo $WARP_BIN --accept-tos mode proxy 2>&1 || true
    sudo $WARP_BIN --accept-tos connect 2>&1 || true
    sleep 2

    # Retry status check — WARP can take several seconds to connect
    WARP_CONNECTED=false
    for i in 1 2 3 4 5 6; do
        if sudo warp-cli --accept-tos status 2>/dev/null | grep -qi "Connected"; then
            echo "up"
            WARP_CONNECTED=true
            break
        fi
        sleep 2
    done
    if [[ "$WARP_CONNECTED" != "true" ]]; then
        echo "down"
        sudo warp-cli --accept-tos status 2>/dev/null || true
    fi

    # Probe SOCKS5
    if ss -tlnp 2>/dev/null | grep -q ':40000 '; then
        log "WARP SOCKS5 listening on :40000"
        WARP_CHECK=$(curl -s --max-time 5 --socks5 127.0.0.1:40000 https://cloudflare.com/cdn-cgi/trace 2>/dev/null) || true
        if echo "$WARP_CHECK" | grep -q 'warp='; then
            WARP_ACTIVE=true
            log "WARP ✓ — routing through consumer IPs"
        fi
    else
        warn "WARP SOCKS5 not listening on :40000"
    fi

    if [[ "$WARP_ACTIVE" != "true" ]]; then
        warn "WARP not active — Reddit blocking may persist"
    fi
fi
fi   # end RENDER_ONLY else (cloudflared + WARP)

# ─── Generate credentials ────────────────────────────────────────────────────
log "Generating credentials..."

# Derivation functions (pure shell + openssl — no files, no python, all from SEED)
hex2bin() { printf "$(echo "$1" | sed 's/\(..\)/\\x\1/g')"; }

derive_uuid() {
    local h; h=$(echo -n "${SEED}:$1" | sha256sum | head -c 32)
    printf '%s-%s-4%s-a%s-%s' "${h:0:8}" "${h:8:4}" "${h:13:3}" "${h:17:3}" "${h:20:12}"
}

derive_pass() {
    echo -n "${SEED}:$1" | openssl dgst -sha256 -binary | openssl enc -base64 -A | tr -d '=+/' | cut -c1-16
}

derive_hex() {
    echo -n "${SEED}:$1" | sha256sum | head -c "${2:-16}"
}

derive_x25519() {
    local priv_hex f_hex l_hex cf cl
    priv_hex=$(echo -n "${SEED}:$1" | sha256sum | head -c 64)
    f_hex="${priv_hex:0:2}"; l_hex="${priv_hex:62:2}"
    cf=$(printf '%02x' $((0x${f_hex} & 248)))
    cl=$(printf '%02x' $((0x${l_hex} & 127 | 64)))
    priv_hex="${cf}${priv_hex:2:60}${cl}"
    local der_hex="302e020100300506032b656e04220420${priv_hex}"
    # Extract public key DER (~44 bytes SPKI), take last 32 bytes as raw public point
    local pub_hex
    pub_hex=$(hex2bin "$der_hex" | openssl pkey -pubout -outform DER 2>/dev/null \
        | od -A n -t x1 | tr -d ' \n')
    pub_hex="${pub_hex: -64}"
    # xray expects base64url (Go's RawURLEncoding: -_ instead of +/, no padding)
    local b64url="tr '+/' '-_' | tr -d '='"
    echo "$(hex2bin "$priv_hex" | openssl enc -base64 -A | eval "$b64url")"
    echo "$(hex2bin "$pub_hex" | openssl enc -base64 -A | eval "$b64url")"
}

# Assign all credentials deterministically from SEED
UUID_VLESS=$(derive_uuid uuid/vless)
UUID_TROJAN=$(derive_uuid uuid/trojan)
UUID_VMESS=$(derive_uuid uuid/vmess)
UUID_VLESS_GRPC=$(derive_uuid uuid/vless-grpc)
UUID_TROJAN_GRPC=$(derive_uuid uuid/trojan-grpc)
UUID_SHADOWSOCKS=$(derive_uuid uuid/shadowsocks)
UUID_REALITY=$(derive_uuid uuid/reality)
TROJAN_PASS=$(derive_pass pass/trojan)
SS_PASS=$(derive_pass pass/ss)

# Reality x25519 (derive_x25519 outputs: line 1=private, line 2=public)
read -r REALITY_PRIVATE REALITY_PUBLIC <<< "$(derive_x25519 reality/keys | tr '\n' ' ')"

SHORT_ID=$(derive_hex short-id 8)
PATH_VLESS="/$(derive_hex path/vless 16)"
PATH_TROJAN="/$(derive_hex path/trojan 16)"
PATH_VMESS="/$(derive_hex path/vmess 16)"
GRPC_SERVICE_VLESS=$(derive_hex grpc/vless 16)
GRPC_SERVICE_TROJAN=$(derive_hex grpc/trojan 16)
# gRPC nginx locations must match serviceName for gRPC routing to work
PATH_VLESS_GRPC="/${GRPC_SERVICE_VLESS}"
PATH_TROJAN_GRPC="/${GRPC_SERVICE_TROJAN}"

# New external protocols (WS/gRPC through nginx/Cloudflare)
PATH_SS_WS="/$(derive_hex path/ss-ws 16)"
GRPC_SERVICE_SS=$(derive_hex grpc/ss 16)
PATH_SS_GRPC="/${GRPC_SERVICE_SS}"
GRPC_SERVICE_VMESS=$(derive_hex grpc/vmess 16)
PATH_VMESS_GRPC="/${GRPC_SERVICE_VMESS}"

# HTTPUpgrade protocols (new — simpler than WS, works through nginx/CF)
PATH_VLESS_HU="/$(derive_hex path/vless-hu 16)"
PATH_TROJAN_HU="/$(derive_hex path/trojan-hu 16)"
PATH_VMESS_HU="/$(derive_hex path/vmess-hu 16)"

# ─── Export vars for envsubst & render configs ──────────────────────────────
log "Rendering config files from templates..."
mkdir -p "$SUB_DIR" "$LOG_DIR"

# ─── Download geo databases (Iran rules) ────────────────────────────────────
# Hosted on this server so clients don't depend on GitHub for geo data.
#   Country.mmdb          → Shadowrocket (Settings → GeoLite2 数据库)
#   geoip.dat/geosite.dat → xray-family clients (v2rayN / v2rayNG)
#   geoip.db/geosite.db   → sing-box clients (NekoBox — manual import)
# Cached by date: if files for today exist in CACHE_DIR/geo/YYYY-MM-DD/, reuse them.
download_geo() {
    local today=$(date +%F)
    local cache_base="${HOME}/.cache/gayroxy/geo/${today}"
    local cached=0
    if [[ -d "${cache_base}" ]]; then
        mkdir -p "${GEO_DIR}"
        # Hardlink from cache to workspace (fast, no copy on same fs)
        for f in "${cache_base}"/*; do
            [[ -f "$f" ]] && ln -f "$f" "${GEO_DIR}/" 2>/dev/null || cp -f "$f" "${GEO_DIR}/"
        done
        local count=$(ls -1 "${GEO_DIR}" 2>/dev/null | wc -l)
        if (( count > 0 )); then
            log "geo: cache hit (${today}) — ${count} files reused."
            cached=1
        fi
    fi
    if (( cached == 1 )); then
        return 0
    fi

    mkdir -p "${GEO_DIR}"
    # repo | comma-separated asset names to grab from that repo's latest release.
    # Uses the stable /releases/latest/download/ redirect (no api.github.com call —
    # unauthenticated API calls get rate-limited on shared runner egress IPs).
    local -a sources=(
        "Chocolate4U/Iran-v2ray-rules|Country.mmdb,geoip.dat,geosite.dat"
        "Chocolate4U/Iran-sing-box-rules|geoip.db,geosite.db"
    )

    local entry repo assets asset url sum_url expected actual ok attempt
    for entry in "${sources[@]}"; do
        repo="${entry%%|*}"
        assets="${entry#*|}"
        for asset in ${assets//,/ }; do
            url="https://github.com/${repo}/releases/latest/download/${asset}"
            sum_url="https://github.com/${repo}/releases/latest/download/${asset}.sha256sum"
            ok=0
            for attempt in 1 2; do
                if curl -fsSL --max-time 120 -o "${GEO_DIR}/${asset}" "$url"; then
                    if [[ -n "$sum_url" ]] && curl -fsSL --max-time 30 -o "${GEO_DIR}/${asset}.sha256sum" "$sum_url"; then
                        expected=$(awk '{print $1}' "${GEO_DIR}/${asset}.sha256sum")
                        actual=$(sha256sum "${GEO_DIR}/${asset}" | awk '{print $1}')
                        rm -f "${GEO_DIR}/${asset}.sha256sum"
                        if [[ "$expected" == "$actual" ]]; then ok=1; break; fi
                        warn "geo: ${asset} checksum mismatch (attempt ${attempt}/2)"
                    else
                        ok=1; break   # no checksum published — accept download
                    fi
                else
                    warn "geo: ${asset} download failed (attempt ${attempt}/2)"
                fi
                sleep 2
            done
            if [[ "$ok" == "1" ]]; then
                log "geo: ${asset} ready ($(du -h "${GEO_DIR}/${asset}" | cut -f1))"
            else
                warn "geo: ${asset} unavailable — clients will 404 on it"
            fi
        done
    done

    # Populate cache for next runs
    mkdir -p "${cache_base}"
    for f in "${GEO_DIR}"/*; do
        [[ -f "$f" ]] && ln -f "$f" "${cache_base}/" 2>/dev/null || cp -f "$f" "${cache_base}/"
    done
}
download_geo

export XRAY_LOG="${LOG_DIR}/xray.log" \
  XRAY_DIR GEO_DIR LOG_DIR SUB_DIR PORT_NGINX \
  PORT_VLESS PORT_TROJAN PORT_VMESS PORT_VLESS_GRPC PORT_TROJAN_GRPC \
  PORT_SHADOWSOCKS PORT_REALITY PORT_SOCKS5 PORT_HTTP_PROXY \
  PORT_SS_WS PORT_SS_GRPC PORT_VMESS_GRPC \
  PORT_VLESS_HU PORT_TROJAN_HU PORT_VMESS_HU \
  WARP_PORT \
  UUID_VLESS UUID_VLESS_GRPC UUID_VMESS UUID_REALITY \
  TROJAN_PASS SS_PASS \
  PATH_VLESS PATH_TROJAN PATH_VMESS PATH_VLESS_GRPC PATH_TROJAN_GRPC \
  PATH_SS_WS PATH_SS_GRPC PATH_VMESS_GRPC \
  PATH_VLESS_HU PATH_TROJAN_HU PATH_VMESS_HU \
  GRPC_SERVICE_VLESS GRPC_SERVICE_TROJAN \
  GRPC_SERVICE_SS GRPC_SERVICE_VMESS \
  REALITY_PRIVATE REALITY_PUBLIC SHORT_ID REALITY_SNI

envsubst < templates/config.json.tmpl > "$XRAY_CONFIG_FILE"

# Inject WARP routing for Reddit (only if WARP is actually working)
if [[ "$WARP_ACTIVE" == "true" ]]; then
    python3 -c "
import json
p = '$XRAY_CONFIG_FILE'
cfg = json.load(open(p))
cfg.setdefault('routing', {}).setdefault('rules', []).append({
    'type': 'field',
    'outboundTag': 'warp',
    'domain': ['reddit.com', 'www.reddit.com', 'redd.it',
               'redditmedia.com', 'redditstatic.com']
})
json.dump(cfg, open(p, 'w'), indent=2)
" && log "Reddit traffic routed through WARP ✓" || warn "Failed to inject WARP routing rule"
fi

# For nginx: only expand OUR variables, leave nginx's own vars ($http_upgrade, etc.)
NGINX_VARS='$XRAY_DIR $GEO_DIR $LOG_DIR $PORT_NGINX $SUB_DIR $PATH_VLESS $PORT_VLESS $PATH_TROJAN $PORT_TROJAN $PATH_VMESS $PORT_VMESS $PATH_VLESS_GRPC $PORT_VLESS_GRPC $PATH_TROJAN_GRPC $PORT_TROJAN_GRPC $PATH_SS_WS $PORT_SS_WS $PATH_SS_GRPC $PORT_SS_GRPC $PATH_VMESS_GRPC $PORT_VMESS_GRPC $PATH_VLESS_HU $PORT_VLESS_HU $PATH_TROJAN_HU $PORT_TROJAN_HU $PATH_VMESS_HU $PORT_VMESS_HU'
envsubst "$NGINX_VARS" < templates/nginx.conf.tmpl > "$NGINX_CONF"

# ─── Start services (skipped in RENDER_ONLY mode) ───────────────────────────
# Respect an externally-supplied TUNNEL_DOMAIN (the quick-tunnel re-deploy step
# passes the live URL this way). Only clear it when we're about to start our own
# tunnel (non-RENDER_ONLY); in RENDER_ONLY a pre-set value is the source of truth.
if [[ "$RENDER_ONLY" == "1" ]]; then
    : "${TUNNEL_DOMAIN:=}"
else
    TUNNEL_DOMAIN=""

# ─── Start xray first ────────────────────────────────────────────────────────
log "Starting Xray-core..."
"$XRAY_BIN" run -c "$XRAY_CONFIG_FILE" > "${LOG_DIR}/xray-output.log" 2>&1 &
XRAY_PID=$!

sleep 1
if ! kill -0 "$XRAY_PID" 2>/dev/null; then
    error "Xray failed to start. Logs:"
    tail -n 20 "${LOG_DIR}/xray-output.log" 2>/dev/null || true
    exit 1
fi
log "Xray running (PID: $XRAY_PID)"

# ─── Start nginx ─────────────────────────────────────────────────────────────
if ! nginx -t -c "${NGINX_CONF}" > /dev/null 2>&1; then
    error "nginx config test failed:"
    nginx -t -c "${NGINX_CONF}"
    exit 1
fi

nginx -c "${NGINX_CONF}" -p "${XRAY_DIR}"
log "nginx running on port ${PORT_NGINX}"

curl -sI "http://127.0.0.1:${PORT_NGINX}/" > /dev/null 2>&1 && log "nginx responds locally ✔" || {
    error "nginx not responding locally. Check ${LOG_DIR}/nginx-error.log"
    exit 1
}

# ─── Tunnel handover lock (high #1) ────────────────────────────────────────
# If a previous run's tunnel is still alive (this run was dispatched early for
# a zero-downtime handover), wait for it to drop before registering ours.
# Two tunnels on the same hostname would flap — never start while one lives.
# If the old tunnel survives the wait, DEFER: exit cleanly and let the current
# run's own end-of-cycle retrigger spawn the next one.
# NOTE: named-tunnel mode only. Quick tunnels get a fresh random URL every
# run — there is nothing to hand over; the old URL simply dies with its run.
# Liveness probe: tunnel is ALIVE only on a real 2xx/3xx from the tunnel's own
# nginx. Cloudflare error pages (530 no-tunnel, 521/522 origin down) must count
# as DOWN — plain `curl -s` exits 0 on ANY HTTP response, which fooled the lock
# into thinking a dead tunnel was alive (chain died silently). We probe /sub
# which nginx always serves while the proxy runs.
tunnel_alive() {
    curl -sf -o /dev/null --max-time 8 "https://${CF_DOMAIN}/sub" 2>/dev/null
}
if [[ "$AUTO_RETRIGGER" == "1" && -n "$CF_DOMAIN" ]]; then
    lock_attempts=0
    lock_max=$(( (RETRIGGER_LEAD_MIN + 3) * 60 / 10 ))   # ~11 min at 10s ticks
    while (( lock_attempts < lock_max )); do
        if ! tunnel_alive; then
            log "Old tunnel down — taking over (after $((lock_attempts * 10))s)."
            break
        fi
        lock_attempts=$((lock_attempts + 1))
        sleep 10
    done
    if (( lock_attempts >= lock_max )); then
        log "Old tunnel still up after $((lock_max * 10))s — deferring to current run's cycle."
        exit 0
    fi
fi

# ─── Start Cloudflare Tunnel ────────────────────────────────────────────────
CLOUDFLARED_LOG="${LOG_DIR}/cloudflared.log"
TUNNEL_DOMAIN=""
if [[ -n "$CF_AUTHTOKEN" && -n "$CF_DOMAIN" ]]; then

    "$CLOUDFLARED_BIN" tunnel --no-autoupdate run --token "${CF_AUTHTOKEN}" --url "http://127.0.0.1:${PORT_NGINX}" >"${CLOUDFLARED_LOG}" 2>&1 &
    CLOUDFLARED_PID=$!

    MAX_RETRIES=30
    TUNNEL_UP=0
    for ((i=1; i<=MAX_RETRIES; i++)); do
        sleep 2
        if ! kill -0 "$CLOUDFLARED_PID" 2>/dev/null; then
            error "cloudflared died. Log:"
            tail -n 20 "${CLOUDFLARED_LOG}" 2>/dev/null || true
            exit 1
        fi
        if grep -q "Registered tunnel connection" "${CLOUDFLARED_LOG}" 2>/dev/null; then
            TUNNEL_UP=1
            break
        fi
    done

    if [[ "$TUNNEL_UP" -ne 1 ]]; then
        error "Cloudflare tunnel failed to establish within timeout."
        tail -n 30 "${CLOUDFLARED_LOG}" || true
        exit 1
    fi
    TUNNEL_DOMAIN="$CF_DOMAIN"
    log "Cloudflare tunnel established for domain: ${CF_DOMAIN}"
else
    # QUICK TUNNEL — zero-config mode: no account, no token, no domain.
    # cloudflared gets a fresh random https://<random>.trycloudflare.com URL.
    log "Starting Cloudflare quick tunnel (zero-config — no account/domain needed)..."
    "$CLOUDFLARED_BIN" tunnel --no-autoupdate --url "http://127.0.0.1:${PORT_NGINX}" >"${CLOUDFLARED_LOG}" 2>&1 &
    CLOUDFLARED_PID=$!

    for ((i=1; i<=60; i++)); do   # up to 120s
        sleep 2
        if ! kill -0 "$CLOUDFLARED_PID" 2>/dev/null; then
            error "cloudflared (quick tunnel) died. Log:"
            tail -n 20 "${CLOUDFLARED_LOG}" 2>/dev/null || true
            exit 1
        fi
        TUNNEL_DOMAIN=$(grep -oP 'https://\K[a-z0-9-]+\.trycloudflare\.com' "${CLOUDFLARED_LOG}" 2>/dev/null | head -1)
        [[ -n "$TUNNEL_DOMAIN" ]] && break
    done

    if [[ -z "$TUNNEL_DOMAIN" ]]; then
        error "Quick tunnel URL not obtained within timeout."
        tail -n 30 "${CLOUDFLARED_LOG}" || true
        exit 1
    fi
    log "Quick tunnel established: https://${TUNNEL_DOMAIN}"
fi
fi   # end RENDER_ONLY guard (services block)

# ─── Build subscription URLs ──────────────────────────────────────────────────
# Live tunnel (proxy job) → use its domain. Named-tunnel RENDER_ONLY → the
# stable custom domain. Quick-tunnel RENDER_ONLY → no tunnel in this job:
# reuse the last known URL from the deployed sub (retrigger chains), else a
# placeholder — the proxy job re-deploys Pages with the real URL ~2 min after
# its tunnel boots.
if [[ -n "$TUNNEL_DOMAIN" ]]; then
    DOMAIN="$TUNNEL_DOMAIN"
elif [[ -n "$CF_DOMAIN" ]]; then
    DOMAIN="$CF_DOMAIN"
else
    DOMAIN=$(curl -sL --max-time 8 "${WORKER_URL}/sub.txt" 2>/dev/null | base64 -d 2>/dev/null | grep -oP '(?<=@)[^:]+' | head -1 || true)
    DOMAIN="${DOMAIN:-tunnel-coming-on-first-run.trycloudflare.com}"
    log "No live tunnel in this job — sub uses ${DOMAIN} (proxy job will re-deploy with the real URL)"
fi

ENC_PATH_VLESS=$(python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1]))" "${PATH_VLESS}")
ENC_PATH_TROJAN=$(python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1]))" "${PATH_TROJAN}")

VLESS_URL="vless://${UUID_VLESS}@${DOMAIN}:443?type=ws&security=tls&fp=chrome&packetEncoding=xudp&host=${DOMAIN}&path=${ENC_PATH_VLESS}&sni=${DOMAIN}&encryption=none#Gayroxy-🇺🇳-VLESS-WS"

TROJAN_URL="trojan://${TROJAN_PASS}@${DOMAIN}:443?type=ws&security=tls&fp=chrome&host=${DOMAIN}&path=${ENC_PATH_TROJAN}&sni=${DOMAIN}#Gayroxy-🇺🇳-Trojan-WS"

VMESS_JSON="{\"v\":\"2\",\"ps\":\"Gayroxy-🇺🇳-VMess-WS\",\"add\":\"${DOMAIN}\",\"port\":\"443\",\"id\":\"${UUID_VMESS}\",\"aid\":\"0\",\"net\":\"ws\",\"type\":\"none\",\"host\":\"${DOMAIN}\",\"path\":\"${PATH_VMESS}\",\"tls\":\"tls\",\"sni\":\"${DOMAIN}\",\"fp\":\"chrome\"}"
VMESS_URL="vmess://$(echo -n "$VMESS_JSON" | base64 -w 0)"

VLESS_GRPC_URL="vless://${UUID_VLESS_GRPC}@${DOMAIN}:443?type=grpc&security=tls&fp=chrome&host=${DOMAIN}&serviceName=${GRPC_SERVICE_VLESS}&sni=${DOMAIN}&encryption=none#Gayroxy-🇺🇳-VLESS-gRPC"

TROJAN_GRPC_URL="trojan://${TROJAN_PASS}@${DOMAIN}:443?type=grpc&security=tls&fp=chrome&host=${DOMAIN}&serviceName=${GRPC_SERVICE_TROJAN}&sni=${DOMAIN}#Gayroxy-🇺🇳-Trojan-gRPC"

SS_BASE="$(echo -n "aes-256-gcm:${SS_PASS}" | base64 -w 0)"
SS_URL="ss://${SS_BASE}@127.0.0.1:${PORT_SHADOWSOCKS}#Gayroxy-🇺🇳-SS-Local"

REALITY_LOCAL_URL="vless://${UUID_REALITY}@127.0.0.1:${PORT_REALITY}?security=reality&flow=xtls-rprx-vision&fp=chrome&pbk=${REALITY_PUBLIC}&sid=${SHORT_ID}&type=tcp&sni=${REALITY_SNI}#Gayroxy-🇺🇳-Reality-Local"

# New external protocols (WS/gRPC through Cloudflare tunnel)
SS_WS_URL="ss://$(echo -n "aes-256-gcm:${SS_PASS}" | base64 -w 0)@${DOMAIN}:443?type=ws&security=tls&path=${PATH_SS_WS}&host=${DOMAIN}#Gayroxy-🇺🇳-SS-WS"
SS_GRPC_URL="ss://$(echo -n "aes-256-gcm:${SS_PASS}" | base64 -w 0)@${DOMAIN}:443?type=grpc&security=tls&serviceName=${GRPC_SERVICE_SS}&host=${DOMAIN}#Gayroxy-🇺🇳-SS-gRPC"

VMESS_GRPC_JSON="{\"v\":\"2\",\"ps\":\"Gayroxy-🇺🇳-VMess-gRPC\",\"add\":\"${DOMAIN}\",\"port\":\"443\",\"id\":\"${UUID_VMESS}\",\"aid\":\"0\",\"net\":\"grpc\",\"type\":\"none\",\"host\":\"${DOMAIN}\",\"path\":\"${GRPC_SERVICE_VMESS}\",\"tls\":\"tls\",\"sni\":\"${DOMAIN}\",\"fp\":\"chrome\"}"
VMESS_GRPC_URL="vmess://$(echo -n "$VMESS_GRPC_JSON" | base64 -w 0)"

# HTTPUpgrade protocols (new — simpler alternative to WS, works through nginx/CF)
VLESS_HU_URL="vless://${UUID_VLESS}@${DOMAIN}:443?type=httpupgrade&security=tls&fp=chrome&host=${DOMAIN}&path=${PATH_VLESS_HU}&sni=${DOMAIN}&encryption=none#Gayroxy-🇺🇳-VLESS-HU"
TROJAN_HU_URL="trojan://${TROJAN_PASS}@${DOMAIN}:443?type=httpupgrade&security=tls&fp=chrome&host=${DOMAIN}&path=${PATH_TROJAN_HU}&sni=${DOMAIN}#Gayroxy-🇺🇳-Trojan-HU"
VMESS_HU_JSON="{\"v\":\"2\",\"ps\":\"Gayroxy-🇺🇳-VMess-HU\",\"add\":\"${DOMAIN}\",\"port\":\"443\",\"id\":\"${UUID_VMESS}\",\"aid\":\"0\",\"net\":\"httpupgrade\",\"type\":\"none\",\"host\":\"${DOMAIN}\",\"path\":\"${PATH_VMESS_HU}\",\"tls\":\"tls\",\"sni\":\"${DOMAIN}\",\"fp\":\"chrome\"}"
VMESS_HU_URL="vmess://$(echo -n "$VMESS_HU_JSON" | base64 -w 0)"

SOCKS5_URL="socks5://127.0.0.1:${PORT_SOCKS5}#Gayroxy-🇺🇳-Socks5"
HTTP_URL="http://127.0.0.1:${PORT_HTTP_PROXY}#Gayroxy-🇺🇳-HTTP"

# ─── Build subscription file ──────────────────────────────────────────────────
SUB_CONTENT="${VLESS_URL}
${TROJAN_URL}
${VMESS_URL}
${VLESS_GRPC_URL}
${TROJAN_GRPC_URL}
${SS_URL}
${SS_WS_URL}
${SS_GRPC_URL}
${VMESS_GRPC_URL}
${VLESS_HU_URL}
${TROJAN_HU_URL}
${VMESS_HU_URL}
${REALITY_LOCAL_URL}
${SOCKS5_URL}
${HTTP_URL}"

SUB_B64=$(echo -n "$SUB_CONTENT" | base64 -w 0)
echo -n "$SUB_B64" > "${SUB_DIR}/subscription.b64"

# ─── Merge External Subscriptions ─────────────────────────────────────────────
# EXTERNAL_SUB_URLS: comma-separated list of subscription URLs to merge
# Set as GitHub secret or env var: EXTERNAL_SUB_URLS="https://sub1.com/sub,https://sub2.com/sub"
#
# Each merged external config gets its remark renamed to match the Gayroxy
# naming style, tagged External so it's easy to tell apart from our own nodes:
#   Gayroxy-🇺🇳-VLESS-WebSocket   (ours)
#   External-🌐-VLESS-WebSocket   (merged from another sub)

# Rename remarks: vless/trojan/ss → replace #fragment; vmess → rewrite base64 "ps"
# Also drops comments/empty lines — only valid proxy links are merged.
rename_external_remarks() {
    python3 -c '
import sys, base64, json, urllib.parse, re
from collections import Counter

def b64pad(s):
    return s + "=" * (-len(s) % 4)

def proto_name(p):
    return {"vless":"VLESS","vmess":"VMess","trojan":"Trojan",
            "ss":"Shadowsocks","shadowsocks":"Shadowsocks"}.get(p, p.upper())

def transport_name(t):
    return {"ws":"WebSocket","grpc":"gRPC","httpupgrade":"HTTPUpgrade",
            "tcp":"TCP"}.get(t, "TCP")

def parse(line):
    m = re.match(r"^(vless|vmess|trojan|ss|shadowsocks)://(.*)$", line)
    if not m:
        return None
    proto, rest = m.group(1), m.group(2)
    if proto == "vmess":
        try:
            data = json.loads(base64.b64decode(b64pad(rest)))
            transport = transport_name(data.get("net", "tcp"))
        except Exception:
            return None
        return proto, transport, data
    query = rest.split("#")[0]
    transport = "TCP"
    sec = ""
    if "?" in query:
        q = urllib.parse.parse_qs(query.split("?", 1)[1])
        transport = transport_name(q.get("type", ["tcp"])[0])
        sec = q.get("security", [""])[0]
    if sec == "reality":
        transport = "Reality"
    return proto, transport, None

seen = Counter()
out = []
for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    parsed = parse(line)
    if not parsed:
        continue
    proto, transport, vmess_data = parsed
    remark = "External-\U0001F310-%s-%s" % (proto_name(proto), transport)
    seen[remark] += 1
    if seen[remark] > 1:
        remark += "-%d" % seen[remark]
    if proto == "vmess":
        vmess_data["ps"] = remark
        rebuilt = "vmess://" + base64.b64encode(
            json.dumps(vmess_data, ensure_ascii=False).encode()).decode()
    else:
        rebuilt = line.split("#")[0] + "#" + remark
    out.append(rebuilt)
print("\n".join(out))
'
}

merge_external_subs() {
    local combined="$SUB_CONTENT"
    local external_count=0
    local gayroxy_count=$(echo -n "$SUB_CONTENT" | grep -c '^' || true)

    if [[ -n "${EXTERNAL_SUB_URLS:-}" ]]; then
        IFS=',' read -ra URLS <<< "$EXTERNAL_SUB_URLS"
        for url in "${URLS[@]}"; do
            url=$(echo "$url" | xargs)  # trim whitespace
            [[ -z "$url" ]] && continue
            log "Fetching external sub: $url"
            local ext_content
            ext_content=$(curl -sL --max-time 15 --retry 2 --retry-delay 3 "$url" 2>/dev/null || true)
            if [[ -z "$ext_content" ]]; then
                warn "  ✗ Failed to fetch (empty response): $url"
                continue
            fi
            # Cloudflare/providers sometimes return an error page (e.g.
            # "error code: 1101") with HTTP 200 — detect and skip so we don't
            # emit a misleading "No valid links" warning.
            if [[ "$ext_content" =~ ^[[:space:]]*error[[:space:]]*code:?[[:space:]]*[0-9]+ ]]; then
                warn "  ✗ Provider error page returned: $url — $(printf '%s' "$ext_content" | head -1)"
                continue
            fi
            # Try decode ONLY if the whole content looks like base64 (no
            # scheme:// → it's likely an encoded sub). Plain text with
            # vless://... lines is left as-is.
            if ! printf '%s' "$ext_content" | grep -qE '^(vless|trojan|vmess|ss|socks5?)://'; then
                if printf '%s' "$ext_content" | base64 -d 2>/dev/null | grep -qE '^(vless|trojan|vmess|ss|socks5?)://'; then
                    ext_content=$(printf '%s' "$ext_content" | base64 -d 2>/dev/null || echo "$ext_content")
                fi
            fi
            # Rename remarks + filter to valid proxy links
            local cleaned
            cleaned=$(printf '%s\n' "$ext_content" | rename_external_remarks)
            local added
            # grep -c exits 1 (printing "0") when empty; `|| echo 0` would append a
            # second 0 → "0\n0", crashing `[[ "$added" -gt 0 ]]`. Use `|| true`.
            added=$(echo -n "$cleaned" | grep -c '^' || true)
            if [[ "${added:-0}" -gt 0 ]]; then
                combined+=$'\n'"$cleaned"
                external_count=$((external_count + added))
                log "  ✓ Merged $added links from $url (remarks → External-🌐-*)"
            else
                warn "  ⚠ No valid links found in: $url"
            fi
        done
    fi

    # Update SUB_CONTENT and SUB_B64 with merged result
    SUB_CONTENT="$combined"
    SUB_B64=$(echo -n "$SUB_CONTENT" | base64 -w 0)
    echo -n "$SUB_B64" > "${SUB_DIR}/subscription.b64"

    # Export for panel template
    export EXTERNAL_SUB_COUNT=$external_count
    export GAYROXY_SUB_COUNT=$gayroxy_count
    export TOTAL_SUB_COUNT=$((gayroxy_count + external_count))
}

merge_external_subs

# Render HTML templates (after tunnel — we have the domain & URLs)
log "Rendering HTML pages..."
envsubst '$DOMAIN $WORKER_URL' < templates/index.html.tmpl > "${SUB_DIR}/index.html"

export WORKER_URL DOMAIN

export SUB_B64 VLESS_URL TROJAN_URL VMESS_URL VLESS_GRPC_URL TROJAN_GRPC_URL
export SS_URL SS_WS_URL SS_GRPC_URL VMESS_GRPC_URL
export VLESS_HU_URL TROJAN_HU_URL VMESS_HU_URL
export REALITY_LOCAL_URL SOCKS5_URL HTTP_URL
export UUID_VLESS PATH_VLESS TROJAN_PASS PATH_TROJAN UUID_VMESS PATH_VMESS
export UUID_VLESS_GRPC GRPC_SERVICE_VLESS GRPC_SERVICE_TROJAN
export SS_PASS PORT_SHADOWSOCKS UUID_REALITY REALITY_PUBLIC PORT_REALITY
export PATH_SS_WS PATH_SS_GRPC PATH_VMESS_GRPC
export PATH_VLESS_HU PATH_TROJAN_HU PATH_VMESS_HU
export GRPC_SERVICE_SS GRPC_SERVICE_VMESS
export PORT_SS_WS PORT_SS_GRPC PORT_VMESS_GRPC
export PORT_VLESS_HU PORT_TROJAN_HU PORT_VMESS_HU
export PORT_SOCKS5 PORT_HTTP_PROXY
export DOMAIN

# Build DATA JSON for the panel template (all URL/credential vars)
export DATA=$(python3 -c "
import json, os
keys = [
    'VLESS_URL','TROJAN_URL','VMESS_URL','VLESS_GRPC_URL','TROJAN_GRPC_URL',
    'SS_URL','SS_WS_URL','SS_GRPC_URL','VMESS_GRPC_URL',
    'VLESS_HU_URL','TROJAN_HU_URL','VMESS_HU_URL',
    'REALITY_LOCAL_URL','SOCKS5_URL','HTTP_URL',
    'UUID_VLESS','UUID_TROJAN','UUID_VMESS','UUID_VLESS_GRPC','UUID_TROJAN_GRPC',
    'UUID_REALITY','TROJAN_PASS','SS_PASS',
    'PATH_VLESS','PATH_TROJAN','PATH_VMESS',
    'PATH_VLESS_GRPC','PATH_TROJAN_GRPC',
    'PATH_SS_WS','PATH_SS_GRPC','PATH_VMESS_GRPC',
    'PATH_VLESS_HU','PATH_TROJAN_HU','PATH_VMESS_HU',
    'GRPC_SERVICE_VLESS','GRPC_SERVICE_TROJAN',
    'GRPC_SERVICE_SS','GRPC_SERVICE_VMESS',
    'PORT_SHADOWSOCKS','PORT_REALITY','PORT_SOCKS5','PORT_HTTP_PROXY',
    'REALITY_PUBLIC','SUB_B64','DOMAIN','WORKER_URL','REALITY_SNI',
    'EXTERNAL_SUB_URLS','EXTERNAL_SUB_COUNT','GAYROXY_SUB_COUNT','TOTAL_SUB_COUNT',
]
d = {k: os.environ.get(k, '') for k in keys}
print(json.dumps(d))
")

envsubst '${DATA} ${DOMAIN} ${WORKER_URL}' < templates/panel.html.tmpl > "${SUB_DIR}/panel.html"

# ─── Final output ─────────────────────────────────────────────────────────
echo ""
echo "=========================================="
echo "  🚀 Multi-Protocol Proxy Ready!"
echo "=========================================="
echo ""
echo -e "  ${MAG}📋 Subscription:${NC} https://${DOMAIN}/sub"
echo -e "  ${MAG}🌐 Worker URL:${NC}  ${WORKER_URL}"
echo -e "  ${MAG}🖥️  Panel:${NC}       https://${DOMAIN}/panel"
echo ""
echo "── 🌐 Cloudflare Tunnel (TLS) ──────────────────"
echo -e "  ${GRN}WebSocket${NC}     VLESS | Trojan | VMess | Shadowsocks"
echo -e "  ${GRN}gRPC${NC}          VLESS | Trojan | VMess | Shadowsocks"
echo -e "  ${GRN}HTTPUpgrade${NC}   VLESS | Trojan | VMess"
echo ""
echo "── 🔒 Local Only ────────────────────────────────"
echo -e "  Shadowsocks :${PORT_SHADOWSOCKS}  Reality:${PORT_REALITY}  SOCKS5:${PORT_SOCKS5}  HTTP:${PORT_HTTP_PROXY}"
echo ""
echo "── 🌍 Geo Data (Iran rules) ─────────────────────────"
echo -e "  Shadowrocket : https://${DOMAIN}/geo/Country.mmdb"
echo -e "  NekoBox      : https://${DOMAIN}/geo/geoip.db  |  geosite.db"
echo -e "  Xray desktop : https://${DOMAIN}/geo/geoip.dat  |  geosite.dat"
echo ""
echo "── 🛡️  Stealth ───────────────────────────────────"
if [[ "$WARP_ACTIVE" == "true" ]]; then
    echo -e "  WARP ${GRN}ACTIVE${NC} — Reddit traffic via consumer IPs ${GRN}✓${NC}"
else
    echo -e "  WARP ${RED}INACTIVE${NC} — Reddit may still block (datacenter IP)"
fi
echo ""
echo -e "  ${YEL}Quick link:${NC} ${VLESS_URL}"
echo ""
echo "=========================================="
echo ""

# RENDER_ONLY mode: done after assets are generated (no long-lived process)
if [[ "$RENDER_ONLY" == "1" ]]; then
    log "RENDER_ONLY — assets generated. Skipping long-lived proxy (exit 0)."
    exit 0
fi

# ─── Auto re-trigger (high #1) ─────────────────────────────────────────────
# Fire the next workflow run ~RETRIGGER_LEAD_MIN before this run's timeout so
# the next runner is already booting/render-deploying while we're still up.
# Guard: skip if a successor run is already queued/in_progress (avoid snowball
# when retrigger.sh or another auto-dispatch already fired one).
if [[ "$AUTO_RETRIGGER" == "1" && -n "${GH_TOKEN:-}" ]]; then
    sleep_sec=$(( (RUN_TIMEOUT_MIN - RETRIGGER_LEAD_MIN) * 60 ))
    (
        sleep "$sleep_sec"
        # Skip if a successor run already exists (retrigger.sh or manual dispatch)
        WF_NAME="${GITHUB_WORKFLOW:-Build & Deploy Proxy}"
        REF="${GITHUB_REF_NAME:-master}"
        existing=$(gh run list --workflow "$WF_NAME" --branch "$REF" \
            --json databaseId,status --jq \
            '.[] | select(.databaseId != '"$GITHUB_RUN_ID"' and .status != "completed") | .databaseId' \
            2>/dev/null | head -1)
        if [[ -n "$existing" ]]; then
            log "Auto-re-trigger: successor #$existing already running — skipping dispatch."
        else
            log "Auto-re-trigger: dispatching next run (${RUN_TIMEOUT_MIN}-${RETRIGGER_LEAD_MIN}min elapsed)..."
            gh workflow run "$WF_NAME" --ref "$REF" 2>&1 || true
        fi
    ) &
    RETRIGGER_PID=$!
    log "Auto-re-trigger armed: dispatch in ${sleep_sec}s (pid ${RETRIGGER_PID})"
else
    RETRIGGER_PID=""
fi

# ─── Tunnel watchdog (medium #5) ───────────────────────────────────────────
# If the public endpoint stops responding, signal the main process to exit
# so the re-trigger cycle restarts the tunnel instead of a silent 4-hour outage.
watchdog() {
    local fails=0 endpoint="https://${TUNNEL_DOMAIN}/" main_pid=$$
    while :; do
        sleep "$WATCHDOG_INTERVAL"
        if ! kill -0 "$XRAY_PID" 2>/dev/null; then
            log "watchdog: xray died — signalling main to exit."
            kill -TERM "$main_pid" 2>/dev/null || true
            exit 1
        fi
        if curl -s -o /dev/null --max-time 8 -k "$endpoint" 2>/dev/null; then
            fails=0
        else
            fails=$((fails + 1))
            warn "watchdog: endpoint unreachable (${fails}/${WATCHDOG_FAILS})"
            if (( fails >= WATCHDOG_FAILS )); then
                error "watchdog: tunnel down for ${WATCHDOG_FAILS} checks — signalling main to exit."
                kill -TERM "$main_pid" 2>/dev/null || true
                exit 1
            fi
        fi
    done
}
watchdog &
WATCHDOG_PID=$!

log "Running... (Ctrl-C to stop)"
wait "$XRAY_PID"
# Reached only if xray exits; watchdog signals TERM to main which runs cleanup.
wait "$WATCHDOG_PID" 2>/dev/null || true
[[ -n "$RETRIGGER_PID" ]] && kill "$RETRIGGER_PID" 2>/dev/null || true
exit 0

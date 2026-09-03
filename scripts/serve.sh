#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────────────
# serve.sh — LONG-LIVED supervisor job (runs on the 240-min runner).
# Boots xray+nginx+cloudflared tunnel, then owns health-agent (background child),
# auto-re-trigger, and the tunnel watchdog for the full job lifetime. This is the
# ONLY job allowed to hold long-lived processes (GitHub gives each job a fresh
# runner; a process cannot outlive its job).
# ──────────────────────────────────────────────────────────────────────────────
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "${SCRIPT_DIR}/scripts/lib/common.sh"
source "${SCRIPT_DIR}/scripts/lib/cloudflare.sh"

export RENDER_ONLY=0
export HEALTH_AGENT=1
export AUTO_RETRIGGER="${AUTO_RETRIGGER:-1}"
RUN_TIMEOUT_MIN="${RUN_TIMEOUT_MIN:-240}"
RETRIGGER_LEAD_MIN="${RETRIGGER_LEAD_MIN:-15}"
WATCHDOG_INTERVAL="${WATCHDOG_INTERVAL:-120}"
WATCHDOG_FAILS="${WATCHDOG_FAILS:-3}"
HEALTH_INTERVAL="${HEALTH_INTERVAL:-120}"
SUBS_REFRESH_INTERVAL="${SUBS_REFRESH_INTERVAL:-1800}"
ROTATE1MIN_INTERVAL="${ROTATE1MIN_INTERVAL:-60}"
ROTATE2MIN_INTERVAL="${ROTATE2MIN_INTERVAL:-120}"
ROTATE5MIN_INTERVAL="${ROTATE5MIN_INTERVAL:-300}"
ROTATEWARP2MIN_INTERVAL="${ROTATEWARP2MIN_INTERVAL:-120}"
ROTATEWARP4MIN_INTERVAL="${ROTATEWARP4MIN_INTERVAL:-240}"
ROTATEWARP6MIN_INTERVAL="${ROTATEWARP6MIN_INTERVAL:-360}"
PARALLEL_PROBES="${PARALLEL_PROBES:-10}"

mkdir -p "${LOG_DIR}" "${SUB_DIR}" "${XRAY_DIR}"

XRAY_CONFIG_FILE="${XRAY_DIR}/config.json"
NGINX_CONF="${XRAY_DIR}/nginx.conf"

# ─── Install deps + xray + cloudflared + WARP ────────────────────────────────

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

# ─── WARP rotation planes (3 free WARP registrations = 3 distinct IPs) ─────
# Runs N independent warp-go (viacipher/warp) instances, each on its own SOCKS5
# port with its own WARP registration, so each plane has a different Cloudflare
# egress IP/location. The rotation aux xrays cycle through these planes, giving
# a config that changes identity on demand. Opportunistic: if warp-go won't
# install or a plane doesn't come up, WARP_PLANES_ACTIVE stays false and the
# health agent simply writes empty warp rotation configs (graceful degradation).
WARP_PLANES_ACTIVE=false
start_warp_planes(){
  local planedir="${LOG_DIR}/warp-planes"
  mkdir -p "$planedir"
  local warpbinst
  warpbinst=$(command -v warp-go 2>/dev/null || true)
  if [[ -z "$warpbinst" ]]; then
    log "Downloading warp-go (free multi-IP WARP)..."
    local url arch
    arch=$(uname -m)
    case "$arch" in
      x86_64)  url="https://github.com/viacipher/warp/releases/latest/download/warp-go-linux-amd64" ;;
      aarch64) url="https://github.com/viacipher/warp/releases/latest/download/warp-go-linux-arm64" ;;
      *)       warn "Unsupported arch for warp planes: $arch"; return 1 ;;
    esac
    if ! curl -fsSL --max-time 90 -o "$PWD/warp-go" "$url" 2>/dev/null; then
      warn "warp-go download failed — WARP identity rotation unavailable"
      return 1
    fi
    chmod +x "$PWD/warp-go"
    warpbinst="$PWD/warp-go"
  fi

  local -a ports=()
  read -r -a ports <<< "$WARP_PLANE_PORTS"
  [[ ${#ports[@]} -ge 3 ]] || { warn "WARP_PLANE_PORTS must list 3 ports"; return 1; }
  local p cfg
  for p in "${ports[@]}"; do
    cfg="$planedir/plane-$p.json"
    if [[ ! -f "$cfg" ]]; then
      # Canonical warp-go config: headless SOCKS5 server; empty SecretKey tells
      # warp-go to register a fresh free WARP identity on first start, giving
      # this plane its own egress IP. Kept true by warp-go writing the key back.
      cat > "$cfg" <<EOF
{"Device":{"Interface":{"IPv4":"auto","MTU":1280},"Socks5":{"Enable":true,"Listen":"127.0.0.1:$p","Users":null},"SecretKey":null},"Wgcf":{"V4":true,"V6":true}}
EOF
    fi
    ( exec "$warpbinst" -c "$cfg" >> "$planedir/plane-$p.log" 2>&1 ) &
  done

  # Wait for each SOCKS port + confirm it really egresses through WARP.
  local ok=0 p probe
  for p in "${ports[@]}"; do
    for _ in 1 2 3 4 5 6 7 8 9 10; do
      probe=$(curl -fsS --max-time 6 --socks5 "127.0.0.1:$p" https://cloudflare.com/cdn-cgi/trace 2>/dev/null || true)
      if echo "$probe" | grep -q 'warp='; then
        log "WARP plane port $p ✓ — distinct egress up"
        ok=$((ok+1)); break
      fi
      sleep 2
    done
  done
  if [[ $ok -ge 1 ]]; then
    WARP_PLANES_ACTIVE=true
    log "WARP planes up: $ok/${#ports[@]} — identity rotation available"
  else
    warn "No WARP plane came up — identity rotation unavailable (will degrade to existing pool rotation)"
  fi
  export WARP_PLANES_ACTIVE WARP_PLANE_PORTS
}

# ─── Generate credentials ────────────────────────────────────────────────────

# ─── Download geo databases (Iran rules) ────────────────────────────────────
# Hosted on this server so clients don't depend on GitHub for geo data.
#   Country.mmdb          → Shadowrocket (Settings → GeoLite2 数据库)
#   geoip.dat/geosite.dat → xray-family clients (v2rayN / v2rayNG)
#   geoip.db/geosite.db   → sing-box clients (NekoBox — manual import)
# Cached by date: if files for today exist in CACHE_DIR/geo/YYYY-MM-DD/, reuse them.
download_geo() {
    local today
    today=$(date +%F)
    local cache_base="${HOME}/.cache/gayroxy/geo/${today}"
    local cached=0

    # If all required assets are already present (e.g. restored from the
    # GitHub Actions cache), reuse them — no re-download of ~150MB per run.
    local -a required=(Country.mmdb geoip.dat geosite.dat geoip.db geosite.db)
    local missing=0 asset
    for asset in "${required[@]}"; do
        [[ -f "${GEO_DIR}/${asset}" ]] || missing=1
    done
    if (( missing == 0 )); then
        log "geo: all ${#required[@]} assets present in GEO_DIR — reusing (cache hit)."
        return 0
    fi

    if [[ -d "${cache_base}" ]]; then
        mkdir -p "${GEO_DIR}"
        # Hardlink from cache to workspace (fast, no copy on same fs)
        for f in "${cache_base}"/*; do
            [[ -f "$f" ]] && ln -f "$f" "${GEO_DIR}/" 2>/dev/null || cp -f "$f" "${GEO_DIR}/"
        done
        local count
        count=$(ls -1 "${GEO_DIR}" 2>/dev/null | wc -l)
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
  WARP_PORT WARP_PLANE_PORTS \
  PORT_ROTATE_WARP2MIN PORT_ROTATE_WARP4MIN PORT_ROTATE_WARP6MIN \
  UUID_VLESS UUID_VLESS_GRPC UUID_VMESS UUID_REALITY \
  TROJAN_PASS SS_PASS \
  PATH_VLESS PATH_TROJAN PATH_VMESS PATH_VLESS_GRPC PATH_TROJAN_GRPC \
  PATH_SS_WS PATH_SS_GRPC PATH_VMESS_GRPC \
  PATH_VLESS_HU PATH_TROJAN_HU PATH_VMESS_HU \
  PATH_ROTATE1MIN UUID_ROTATE1MIN PATH_ROTATE2MIN UUID_ROTATE2MIN PATH_ROTATE5MIN UUID_ROTATE5MIN \
  PATH_ROTATE_WARP2MIN UUID_ROTATE_WARP2MIN PATH_ROTATE_WARP4MIN UUID_ROTATE_WARP4MIN PATH_ROTATE_WARP6MIN UUID_ROTATE_WARP6MIN \
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
NGINX_VARS='$XRAY_DIR $GEO_DIR $LOG_DIR $PORT_NGINX $SUB_DIR $PATH_VLESS $PORT_VLESS $PATH_TROJAN $PORT_TROJAN $PATH_VMESS $PORT_VMESS $PATH_VLESS_GRPC $PORT_VLESS_GRPC $PATH_TROJAN_GRPC $PORT_TROJAN_GRPC $PATH_SS_WS $PORT_SS_WS $PATH_SS_GRPC $PORT_SS_GRPC $PATH_VMESS_GRPC $PORT_VMESS_GRPC $PATH_VLESS_HU $PORT_VLESS_HU $PATH_TROJAN_HU $PORT_TROJAN_HU $PATH_VMESS_HU $PORT_VMESS_HU $PATH_ROTATE1MIN $PATH_ROTATE2MIN $PATH_ROTATE5MIN $PATH_ROTATE_WARP2MIN $PATH_ROTATE_WARP4MIN $PATH_ROTATE_WARP6MIN'
envsubst "$NGINX_VARS" < templates/nginx.conf.tmpl > "$NGINX_CONF"

# ─── Resolve TUNNEL_DOMAIN (named mode) ──────────────────────────────
if [[ "$RENDER_ONLY" == "1" ]]; then
    : "${TUNNEL_DOMAIN:=}"
else
    TUNNEL_DOMAIN=""
    # Named mode: resolve the static hostname EARLY (read-only account+zone
    # lookups) so the handover lock below can probe it. On failure (no CF_TOKEN
    # or no zone) TUNNEL_DOMAIN stays empty → quick-tunnel fallback later.
    if [[ -n "$CF_TOKEN" ]]; then
        resolve_named_host || TUNNEL_DOMAIN=""
    fi
fi

# ─── Start xray first ────────────────────────────────────────────────────────
log "Starting Xray-core..."
start_xray() {
    "$XRAY_BIN" run -c "$XRAY_CONFIG_FILE" > "${LOG_DIR}/xray-output.log" 2>&1 &
    XRAY_PID=$!
    log "Xray running (PID: $XRAY_PID)"
}
start_xray

# Xray supervisor: restart on crash (max 3 restarts, then hard exit)
XRAY_RESTARTS=0
MAX_XRAY_RESTARTS=3
supervise_xray() {
    while :; do
        wait "$XRAY_PID" 2>/dev/null || true
        # If we're here, Xray exited
        if ! kill -0 "$XRAY_PID" 2>/dev/null; then
            if (( XRAY_RESTARTS >= MAX_XRAY_RESTARTS )); then
                error "Xray crashed ${XRAY_RESTARTS} times — giving up. Log tail:"
                tail -n 30 "${LOG_DIR}/xray-output.log" 2>/dev/null || true
                # Signal main to exit (will trigger re-trigger cycle)
                kill -TERM $$ 2>/dev/null || true
                exit 1
            fi
            XRAY_RESTARTS=$((XRAY_RESTARTS + 1))
            warn "Xray crashed (restart ${XRAY_RESTARTS}/${MAX_XRAY_RESTARTS}) — restarting in 5s..."
            sleep 5
            start_xray
        fi
    done
}
supervise_xray &
XRAY_SUPERVISOR_PID=$!
log "Xray supervisor started (PID: $XRAY_SUPERVISOR_PID, max restarts: $MAX_XRAY_RESTARTS)"

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
    curl -sf -o /dev/null --max-time 8 "https://${TUNNEL_DOMAIN}/sub" 2>/dev/null
}
if [[ "$AUTO_RETRIGGER" == "1" && -n "$TUNNEL_DOMAIN" ]]; then
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
if [[ -n "$CF_TOKEN" && -n "$TUNNEL_DOMAIN" ]]; then
    # NAMED TUNNEL — fully automatic via CF API (CF_TOKEN only). The static
    # hostname was already resolved above (handover lock uses it); now create-
    # or-reuse the tunnel and point DNS at it.
    if bootstrap_named_tunnel; then
        "$CLOUDFLARED_BIN" tunnel --no-autoupdate run --token "${TUNNEL_TOKEN}" --url "http://127.0.0.1:${PORT_NGINX}" >"${CLOUDFLARED_LOG}" 2>&1 &
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
        log "Cloudflare tunnel established for domain: ${TUNNEL_DOMAIN}"
    else
        warn "Named-tunnel bootstrap failed — falling back to quick tunnel."
        TUNNEL_DOMAIN=""
    fi
fi
if [[ -z "$TUNNEL_DOMAIN" ]]; then
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
        TUNNEL_DOMAIN=$(grep -oP 'https://\K[a-z0-9-]+\.trycloudflare\.com' "${CLOUDFLARED_LOG}" 2>/dev/null | head -1 || true)
        [[ -n "$TUNNEL_DOMAIN" ]] && break
    done

    if [[ -z "$TUNNEL_DOMAIN" ]]; then
        error "Quick tunnel URL not obtained within timeout."
        tail -n 30 "${CLOUDFLARED_LOG}" || true
        exit 1
    fi
    log "Quick tunnel established: https://${TUNNEL_DOMAIN}"
fi

if [[ -n "$TUNNEL_DOMAIN" ]]; then
    DOMAIN="$TUNNEL_DOMAIN"
    export DOMAIN
    log "Serving on https://${DOMAIN}"
else
    error "No tunnel domain after tunnel start — aborting."
    exit 1
fi

# ─── LIVE_DEPLOY — publish live assets to Cloudflare (tunnel now up) ─────────
# (The workflow's old run-end Publish step published a dying URL — removed.)
# deploy-cf.sh is idempotent and binds the SAME derived API_TOKEN (exported in
# common.sh) to the Worker, matching what the health agent sends.
if [[ "$LIVE_DEPLOY" == "1" && "$RENDER_ONLY" != "1" ]]; then
    log "LIVE_DEPLOY — publishing live assets to Cloudflare (tunnel: ${DOMAIN})..."
    if [[ -z "${CF_TOKEN:-}" ]]; then
        warn "LIVE_DEPLOY set but CF_TOKEN missing — skipping Cloudflare push."
        warn "(The deploy step in CI normally provides CF_TOKEN.)"
    else
        if "${SCRIPT_DIR}/scripts/publish/deploy-cf.sh"; then
            log "Live assets published: sub.txt now points at https://${DOMAIN}"
        else
            warn "deploy-cf.sh failed — live URL not published (see logs above)."
        fi
    fi
fi

if [[ "$RENDER_ONLY" != "1" && "$HEALTH_AGENT" == "1" ]]; then
    (
        export HEALTH_INTERVAL SUBS_REFRESH_INTERVAL ROTATE1MIN_INTERVAL ROTATE2MIN_INTERVAL ROTATE5MIN_INTERVAL ROTATEWARP2MIN_INTERVAL ROTATEWARP4MIN_INTERVAL ROTATEWARP6MIN_INTERVAL PARALLEL_PROBES HEALTH_TIMEOUT DOMAIN WORKER_URL SEED EXTERNAL_SUB_URLS DEFAULT_EXTERNAL_SUB API_TOKEN SUB_DIR PATH_ROTATE1MIN UUID_ROTATE1MIN PATH_ROTATE2MIN UUID_ROTATE2MIN PATH_ROTATE5MIN UUID_ROTATE5MIN PATH_ROTATE_WARP2MIN UUID_ROTATE_WARP2MIN PATH_ROTATE_WARP4MIN UUID_ROTATE_WARP4MIN PATH_ROTATE_WARP6MIN UUID_ROTATE_WARP6MIN WARP_PORT WARP_PLANE_PORTS WARP_PLANES_ACTIVE WARP_ACTIVE
        exec ./scripts/agent/health-agent.sh
    ) &
    HEALTH_AGENT_PID=$!
    log "Health agent started (pid ${HEALTH_AGENT_PID}; rotation 1min=${ROTATE1MIN_INTERVAL}s 2min=${ROTATE2MIN_INTERVAL}s 5min=${ROTATE5MIN_INTERVAL}s; warp 2min=${ROTATEWARP2MIN_INTERVAL}s 4min=${ROTATEWARP4MIN_INTERVAL}s 6min=${ROTATEWARP6MIN_INTERVAL}s; parallel=${PARALLEL_PROBES})"
else
    HEALTH_AGENT_PID=""
fi

if [[ "$AUTO_RETRIGGER" == "1" && -n "${GH_TOKEN:-}" ]]; then
    sleep_sec=$(( (RUN_TIMEOUT_MIN - RETRIGGER_LEAD_MIN) * 60 ))
    (
        sleep "$sleep_sec"
        # Skip if a successor run already exists (retrigger.sh or manual dispatch)
        # Note: gh run list filters by file path (.git/workflows/main.yml), not
        # workflow name (API returns "Build & Deploy <run_id>")
        WF_NAME="${GITHUB_WORKFLOW:-Build & Deploy Proxy}"
        REF="${GITHUB_REF_NAME:-master}"
        existing=$(gh run list --branch "$REF" \
            --json databaseId,status,workflowName --jq \
            '.[] | select(.databaseId != '"$GITHUB_RUN_ID"' and .workflowName == "'"$WF_NAME"'" and .status != "completed") | .databaseId' \
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
        if curl -s -o /dev/null --max-time 10 -k "$endpoint" 2>/dev/null; then
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
wait "$XRAY_SUPERVISOR_PID" 2>/dev/null || true
[[ -n "$RETRIGGER_PID" ]] && kill "$RETRIGGER_PID" 2>/dev/null || true
[[ -n "${HEALTH_AGENT_PID:-}" ]] && kill "$HEALTH_AGENT_PID" 2>/dev/null || true
exit 0

#!/usr/bin/env bash
# Shared env, colors, logging, paths, and DERIVATION for all scripts/ phase
# scripts. IMPORTANT: the derivation functions + credential exports are copied
# VERBATIM from proxy.sh (lines 284-501) so every phase produces byte-identical
# UUIDs/paths/API_TOKEN. NEVER "improve" these — the Worker binding and the
# health-agent push auth depend on the exact values.
set -euo pipefail

# ─── Paths / dirs ───────────────────────────────────────────────────────────
XRAY_DIR="${XRAY_DIR:-${PWD}}"
XRAY_CONFIG_FILE="${XRAY_DIR}/config.json"
XRAY_BIN="${XRAY_DIR}/xray"
GEO_DIR="${GEO_DIR:-${XRAY_DIR}/geo}"
NGINX_CONF="${XRAY_DIR}/nginx.conf"
SUB_DIR="${SUB_DIR:-${XRAY_DIR}/sub}"
LOG_DIR="${LOG_DIR:-${XRAY_DIR}/logs}"

# ─── Ports (local only) ─────────────────────────────────────────────────────
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
WARP_PORT="${WARP_PORT:-40000}"

# ─── Cloudflare / tunnel config ─────────────────────────────────────────────
CF_TOKEN="${CF_TOKEN:-}"
TUNNEL_NAME="gaaayroxy"            # fixed named-tunnel name → hostname ${TUNNEL_NAME}.<zone>
TUNNEL_DOMAIN="${TUNNEL_DOMAIN:-}"
WORKER_URL="${WORKER_URL:-${PAGES_URL:-}}"
WORKER_URL="${WORKER_URL%/}"
TUNNEL_NAME_LOWER="$(echo "${TUNNEL_NAME:-gaaayroxy}" | tr 'A-Z' 'a-z')"
REALITY_SNI="${REALITY_SNI:-www.cloudflare.com}"

# Seed for deterministic credentials — same seed = same UUIDs/passwords every run.
SEED="${SEED:-${CF_TOKEN:-${GITHUB_REPOSITORY:-gayroxy}}}"

# Health-agent tuning (used by serve.sh when launching the agent).
HEALTH_AGENT="${HEALTH_AGENT:-1}"
HEALTH_INTERVAL="${HEALTH_INTERVAL:-1200}"
SUBS_REFRESH_INTERVAL="${SUBS_REFRESH_INTERVAL:-7200}"
ROTATE2MIN_INTERVAL="${ROTATE2MIN_INTERVAL:-120}"

# Tunnel watchdog
WATCHDOG_INTERVAL="${WATCHDOG_INTERVAL:-20}"
WATCHDOG_FAILS="${WATCHDOG_FAILS:-3}"

# Auto re-trigger
AUTO_RETRIGGER="${AUTO_RETRIGGER:-0}"
RUN_TIMEOUT_MIN="${RUN_TIMEOUT_MIN:-240}"
RETRIGGER_LEAD_MIN="${RETRIGGER_LEAD_MIN:-8}"

# External subscriptions
EXTERNAL_SUB_URLS="${EXTERNAL_SUB_URLS:-}"
DEFAULT_EXTERNAL_SUB="https://raw.githubusercontent.com/Kolandone/v2raycollector/main/config_lite.txt"

# LIVE_DEPLOY=1 (CI publish job): after the tunnel boots and the sub is rendered
# with the REAL live URL, push everything to Cloudflare (deploy-cf.sh).
LIVE_DEPLOY="${LIVE_DEPLOY:-0}"
RENDER_ONLY="${RENDER_ONLY:-0}"

# ─── Colors / logging ───────────────────────────────────────────────────────
RED='\033[0;31m'; GRN='\033[0;32m'; YEL='\033[1;33m'; BLU='\033[0;34m'
CYAN='\033[0;36m'; MAG='\033[0;35m'; NC='\033[0m'
log()   { echo -e "${GRN}[$(basename "$0")]${NC} $1"; }
warn()  { echo -e "${YEL}[$(basename "$0")] WARNING${NC} $1"; }
error() { echo -e "${RED}[$(basename "$0")] ERROR${NC} $1"; }

# ─── Derivation (VERBATIM from proxy.sh — do not change) ────────────────────
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
    local pub_hex
    pub_hex=$(hex2bin "$der_hex" | openssl pkey -pubout -outform DER 2>/dev/null \
        | od -A n -t x1 | tr -d ' \n')
    pub_hex="${pub_hex: -64}"
    local b64url="tr '+/' '-_' | tr -d '='"
    echo "$(hex2bin "$priv_hex" | openssl enc -base64 -A | eval "$b64url")"
    echo "$(hex2bin "$pub_hex" | openssl enc -base64 -A | eval "$b64url")"
}

# ─── Credential assignment (VERBATIM from proxy.sh) ─────────────────────────
UUID_VLESS=$(derive_uuid uuid/vless)
UUID_TROJAN=$(derive_uuid uuid/trojan)
UUID_VMESS=$(derive_uuid uuid/vmess)
UUID_VLESS_GRPC=$(derive_uuid uuid/vless-grpc)
UUID_TROJAN_GRPC=$(derive_uuid uuid/trojan-grpc)
UUID_SHADOWSOCKS=$(derive_uuid uuid/shadowsocks)
UUID_REALITY=$(derive_uuid uuid/reality)
TROJAN_PASS=$(derive_pass pass/trojan)
SS_PASS=$(derive_pass pass/ss)

read -r REALITY_PRIVATE REALITY_PUBLIC <<< "$(derive_x25519 reality/keys | tr '\n' ' ')"

SHORT_ID=$(derive_hex short-id 8)
PATH_VLESS="/$(derive_hex path/vless 16)"
PATH_TROJAN="/$(derive_hex path/trojan 16)"
PATH_VMESS="/$(derive_hex path/vmess 16)"
GRPC_SERVICE_VLESS=$(derive_hex grpc/vless 16)
GRPC_SERVICE_TROJAN=$(derive_hex grpc/trojan 16)
PATH_VLESS_GRPC="/${GRPC_SERVICE_VLESS}"
PATH_TROJAN_GRPC="/${GRPC_SERVICE_TROJAN}"

PATH_SS_WS="/$(derive_hex path/ss-ws 16)"
GRPC_SERVICE_SS=$(derive_hex grpc/ss 16)
PATH_SS_GRPC="/${GRPC_SERVICE_SS}"
GRPC_SERVICE_VMESS=$(derive_hex grpc/vmess 16)
PATH_VMESS_GRPC="/${GRPC_SERVICE_VMESS}"

PATH_VLESS_HU="/$(derive_hex path/vless-hu 16)"
PATH_TROJAN_HU="/$(derive_hex path/trojan-hu 16)"
PATH_VMESS_HU="/$(derive_hex path/vmess-hu 16)"

PATH_ROTATE2MIN="/$(derive_hex path/rotate2min 16)"
UUID_ROTATE2MIN=$(derive_uuid uuid/rotate2min)

# SECURITY: derive + EXPORT the Worker write token so deploy-cf.sh (Worker
# binding) and health-agent.sh (push auth) always agree. Never bind a random
# secret the agent won't send — that reopens unauthenticated writes.
API_TOKEN=$(derive_hex api/token 32)
export API_TOKEN

# ─── Export ALL derived credentials (proxy.sh's lines 463-478 export block) ─
# The render/serve DATA JSON and nginx config read these from the environment,
# so every phase must see the full set — not just the token. Kept verbatim from
# proxy.sh so sub/panel output is byte-identical.
export XRAY_DIR GEO_DIR LOG_DIR SUB_DIR PORT_NGINX \
  PORT_VLESS PORT_TROJAN PORT_VMESS PORT_VLESS_GRPC PORT_TROJAN_GRPC \
  PORT_SHADOWSOCKS PORT_REALITY PORT_SOCKS5 PORT_HTTP_PROXY \
  PORT_SS_WS PORT_SS_GRPC PORT_VMESS_GRPC \
  PORT_VLESS_HU PORT_TROJAN_HU PORT_VMESS_HU \
  WARP_PORT \
  PATH_VLESS PATH_TROJAN PATH_VMESS PATH_VLESS_GRPC PATH_TROJAN_GRPC \
  PATH_SS_WS PATH_SS_GRPC PATH_VMESS_GRPC \
  PATH_VLESS_HU PATH_TROJAN_HU PATH_VMESS_HU \
  PATH_ROTATE2MIN UUID_ROTATE2MIN \
  GRPC_SERVICE_VLESS GRPC_SERVICE_TROJAN \
  GRPC_SERVICE_SS GRPC_SERVICE_VMESS \
  TROJAN_PASS SS_PASS \
  UUID_VLESS UUID_VLESS_GRPC UUID_VMESS UUID_REALITY \
  REALITY_PRIVATE REALITY_PUBLIC SHORT_ID REALITY_SNI

# ─── DOMAIN resolution (shared across independent runners) ───────────────────
# Every job computes the SAME DOMAIN deterministically so sub/panel/boot-verify
# agree. Priority: explicit TUNNEL_DOMAIN env → resolve_named_host (needs
# CF_TOKEN; defined in lib/cloudflare.sh, sourced by phases that have it).
resolve_domain() {
    if [[ -n "${TUNNEL_DOMAIN:-}" ]]; then
        DOMAIN="$TUNNEL_DOMAIN"
    elif [[ -n "${CF_TOKEN:-}" ]] && [[ "$(type -t resolve_named_host)" == "function" ]] && resolve_named_host; then
        DOMAIN="$TUNNEL_DOMAIN"
    else
        DOMAIN="${DOMAIN:-${WORKER_URL#https://}}"
    fi
    export DOMAIN TUNNEL_DOMAIN
}

# ─── Cleanup (phases override cleanup()) ────────────────────────────────────
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

#!/usr/bin/env bash
# ============================================================
# build-assets.sh — RENDER phase (was proxy.sh RENDER_ONLY=1)
#
# Generates sub/panel/geo/index assets + subscription.b64 fast,
# WITHOUT starting any long-lived service. Runs as the `render`
# CI job. Sourced from proxy.sh's render section (byte-preserved).
#
#   env:
#     RENDER_ONLY=1  (implicit — this script always renders only)
#     CF_TOKEN       (optional — resolves the static named hostname)
#     TUNNEL_ZONE     (optional — pins the named-tunnel zone)
#     SEED            (credential derivation seed)
#     WORKER_URL      (Worker base URL)
#     EXTERNAL_SUB_URLS
#     HEALTH_AGENT=0  (never merge external pool here — agent owns it)
# ============================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "${SCRIPT_DIR}/scripts/lib/common.sh"
source "${SCRIPT_DIR}/scripts/lib/cloudflare.sh"

# Ensure tools the render needs exist (curl/python3 are on the runner; bash is
# required). download_geo uses curl + sha256sum + ln.
command -v curl >/dev/null || { echo "build-assets: curl required"; exit 1; }
command -v python3 >/dev/null || { echo "build-assets: python3 required"; exit 1; }

export RENDER_ONLY=1
export HEALTH_AGENT=0
# RENDER-only mode never starts services/tunnel/WARP (matches proxy.sh RENDER_ONLY).
export WARP_ACTIVE=false WARP_BIN="" CLOUDFLARED_BIN=""

# Ensure output dirs exist (proxy.sh created sub/ + logs/ itself; we run as a
# fresh job step with no prior mkdir, so build-assets.sh must own them).
mkdir -p "${SUB_DIR}" "${LOG_DIR}"

# ─────────────────────────────────────────────────────────────
# GEO download (was proxy.sh lines 381-460)
# ─────────────────────────────────────────────────────────────
download_geo() {
    local today=$(date +%F)
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

# ─────────────────────────────────────────────────────────────
# Resolve domain for URLs (named hostname / rendered sub)
# ─────────────────────────────────────────────────────────────
if [[ -n "$TUNNEL_DOMAIN" ]]; then
    DOMAIN="$TUNNEL_DOMAIN"
elif [[ -n "$CF_TOKEN" ]] && resolve_named_host; then
    # Named-tunnel RENDER_ONLY job: no tunnel starts here, but the sub must
    # use the stable static hostname (same as the proxy job will).
    DOMAIN="$TUNNEL_DOMAIN"
else
    DOMAIN=$(curl -sL --max-time 8 "${WORKER_URL}/sub.txt" 2>/dev/null | base64 -d 2>/dev/null | grep -oP '(?<=@)[^:]+' | head -1 || true)
    DOMAIN="${DOMAIN:-tunnel-coming-on-first-run.trycloudflare.com}"
    log "No live tunnel in this job — sub uses ${DOMAIN} (proxy job will re-deploy with the real URL)"
fi

ENC_PATH_VLESS=$(python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1]))" "${PATH_VLESS}")
ENC_PATH_ROTATE2MIN=$(python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1]))" "${PATH_ROTATE2MIN}")
ENC_PATH_TROJAN=$(python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1]))" "${PATH_TROJAN}")

# Detect runner country for config remarks (e.g. 🇩🇪-VLESS-WS)
RUNNER_CC=$(curl -fsS --max-time 5 'http://ip-api.com/json?fields=countryCode' 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin).get("countryCode","??"))' 2>/dev/null || echo '??')
COUNTRY_FLAG=$(python3 -c "c='${RUNNER_CC}'.upper(); print(''.join(chr(127397+ord(x)) for x in c) if len(c)==2 else '🌐')")
COUNTRY_FLAG=$(python3 -c "c='${RUNNER_CC}'.upper(); print(''.join(chr(127397+ord(x)) for x in c) if len(c)==2 else '🌐')")

VLESS_URL="vless://${UUID_VLESS}@${DOMAIN}:443?type=ws&security=tls&fp=chrome&packetEncoding=xudp&host=${DOMAIN}&path=${ENC_PATH_VLESS}&sni=${DOMAIN}&encryption=none#Gayroxy-${COUNTRY_FLAG}-VLESS-WS"

TROJAN_URL="trojan://${TROJAN_PASS}@${DOMAIN}:443?type=ws&security=tls&fp=chrome&host=${DOMAIN}&path=${ENC_PATH_TROJAN}&sni=${DOMAIN}#Gayroxy-${COUNTRY_FLAG}-Trojan-WS"

VMESS_JSON="{\"v\":\"2\",\"ps\":\"Gayroxy-${COUNTRY_FLAG}-VMess-WS\",\"add\":\"${DOMAIN}\",\"port\":\"443\",\"id\":\"${UUID_VMESS}\",\"aid\":\"0\",\"net\":\"ws\",\"type\":\"none\",\"host\":\"${DOMAIN}\",\"path\":\"${PATH_VMESS}\",\"tls\":\"tls\",\"sni\":\"${DOMAIN}\",\"fp\":\"chrome\"}"
VMESS_URL="vmess://$(echo -n "$VMESS_JSON" | base64 -w 0)"

VLESS_GRPC_URL="vless://${UUID_VLESS_GRPC}@${DOMAIN}:443?type=grpc&security=tls&fp=chrome&host=${DOMAIN}&serviceName=${GRPC_SERVICE_VLESS}&sni=${DOMAIN}&encryption=none#Gayroxy-${COUNTRY_FLAG}-VLESS-gRPC"

TROJAN_GRPC_URL="trojan://${TROJAN_PASS}@${DOMAIN}:443?type=grpc&security=tls&fp=chrome&host=${DOMAIN}&serviceName=${GRPC_SERVICE_TROJAN}&sni=${DOMAIN}#Gayroxy-${COUNTRY_FLAG}-Trojan-gRPC"

SS_BASE="$(echo -n "aes-256-gcm:${SS_PASS}" | base64 -w 0)"
SS_URL="ss://${SS_BASE}@127.0.0.1:${PORT_SHADOWSOCKS}#Gayroxy-${COUNTRY_FLAG}-SS-Local"

REALITY_LOCAL_URL="vless://${UUID_REALITY}@127.0.0.1:${PORT_REALITY}?security=reality&flow=xtls-rprx-vision&fp=chrome&pbk=${REALITY_PUBLIC}&sid=${SHORT_ID}&type=tcp&sni=${REALITY_SNI}#Gayroxy-${COUNTRY_FLAG}-Reality-Local"

# New external protocols (WS/gRPC through Cloudflare tunnel)
SS_WS_URL="ss://$(echo -n "aes-256-gcm:${SS_PASS}" | base64 -w 0)@${DOMAIN}:443?type=ws&security=tls&path=${PATH_SS_WS}&host=${DOMAIN}#Gayroxy-${COUNTRY_FLAG}-SS-WS"
SS_GRPC_URL="ss://$(echo -n "aes-256-gcm:${SS_PASS}" | base64 -w 0)@${DOMAIN}:443?type=grpc&security=tls&serviceName=${GRPC_SERVICE_SS}&host=${DOMAIN}#Gayroxy-${COUNTRY_FLAG}-SS-gRPC"

VMESS_GRPC_JSON="{\"v\":\"2\",\"ps\":\"Gayroxy-${COUNTRY_FLAG}-VMess-gRPC\",\"add\":\"${DOMAIN}\",\"port\":\"443\",\"id\":\"${UUID_VMESS}\",\"aid\":\"0\",\"net\":\"grpc\",\"type\":\"none\",\"host\":\"${DOMAIN}\",\"path\":\"${GRPC_SERVICE_VMESS}\",\"tls\":\"tls\",\"sni\":\"${DOMAIN}\",\"fp\":\"chrome\"}"
VMESS_GRPC_URL="vmess://$(echo -n "$VMESS_GRPC_JSON" | base64 -w 0)"

# HTTPUpgrade protocols (new — simpler alternative to WS, works through nginx/CF)
VLESS_HU_URL="vless://${UUID_VLESS}@${DOMAIN}:443?type=httpupgrade&security=tls&fp=chrome&host=${DOMAIN}&path=${PATH_VLESS_HU}&sni=${DOMAIN}&encryption=none#Gayroxy-${COUNTRY_FLAG}-VLESS-HU"
TROJAN_HU_URL="trojan://${TROJAN_PASS}@${DOMAIN}:443?type=httpupgrade&security=tls&fp=chrome&host=${DOMAIN}&path=${PATH_TROJAN_HU}&sni=${DOMAIN}#Gayroxy-${COUNTRY_FLAG}-Trojan-HU"
VMESS_HU_JSON="{\"v\":\"2\",\"ps\":\"Gayroxy-${COUNTRY_FLAG}-VMess-HU\",\"add\":\"${DOMAIN}\",\"port\":\"443\",\"id\":\"${UUID_VMESS}\",\"aid\":\"0\",\"net\":\"httpupgrade\",\"type\":\"none\",\"host\":\"${DOMAIN}\",\"path\":\"${PATH_VMESS_HU}\",\"tls\":\"tls\",\"sni\":\"${DOMAIN}\",\"fp\":\"chrome\"}"
VMESS_HU_URL="vmess://$(echo -n "$VMESS_HU_JSON" | base64 -w 0)"

ROTATE2MIN_URL="vless://${UUID_ROTATE2MIN}@${DOMAIN}:443?type=ws&security=tls&fp=chrome&packetEncoding=xudp&host=${DOMAIN}&path=${ENC_PATH_ROTATE2MIN}&sni=${DOMAIN}&encryption=none#Gayroxy-🔄-Rotate-2min"

SOCKS5_URL="socks5://127.0.0.1:${PORT_SOCKS5}#Gayroxy-${COUNTRY_FLAG}-Socks5"
HTTP_URL="http://127.0.0.1:${PORT_HTTP_PROXY}#Gayroxy-${COUNTRY_FLAG}-HTTP"

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
${ROTATE2MIN_URL}
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

    if [[ -z "${EXTERNAL_SUB_URLS:-}" ]]; then
        EXTERNAL_SUB_URLS="$DEFAULT_EXTERNAL_SUB"
    fi
    # When HEALTH_AGENT=1, the health agent owns the external pool: it probes
    # every config and emits only the BEST_PER_SUB best-working ones per sub.
    # Appending the raw sub here (uncapped) would exceed that and show the user
    # far more external configs than requested, so we skip it and leave the
    # external section to the agent.
    if [[ "$HEALTH_AGENT" != "1" && -n "${EXTERNAL_SUB_URLS:-}" ]]; then
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
export VLESS_HU_URL TROJAN_HU_URL VMESS_HU_URL ROTATE2MIN_URL
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
    'ROTATE2MIN_URL','API_TOKEN',
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
log "build-assets: ✅ created ${SUB_DIR}/subscription.b64 + ${SUB_DIR}/*.html + ${GEO_DIR}"
exit 0

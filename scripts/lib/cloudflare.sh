#!/usr/bin/env bash
# CF API helpers + named-tunnel bootstrap (extracted verbatim from proxy.sh 519-614).
# Requires common.sh sourced first.

resolve_named_host() {
    local api="https://api.cloudflare.com/client/v4"
    local auth="Authorization: Bearer ${CF_TOKEN}"
    TUNNEL_DOMAIN=""
    TUNNEL_ACCT_ID=""
    TUNNEL_ZONE_ID=""

    # 1. First account (Account Settings:Read)
    TUNNEL_ACCT_ID=$(curl -sf --max-time 15 -H "$auth" "$api/accounts?per_page=1" \
        | python3 -c 'import json,sys; r=json.load(sys.stdin).get("result") or []; print(r[0]["id"] if r else "")') || return 1
    [[ -n "$TUNNEL_ACCT_ID" ]] || { warn "CF API: no account found (token lacks Account Settings:Read?)"; return 1; }

    # 2. Active zone: TUNNEL_ZONE (exact name, if set) or first active by name.
    local zone_name
    if [[ -n "${TUNNEL_ZONE:-}" ]]; then
        read -r zone_name TUNNEL_ZONE_ID < <(curl -sf --max-time 15 -H "$auth" "$api/zones?name=${TUNNEL_ZONE}&status=active&per_page=1" \
            | python3 -c 'import json,sys; r=json.load(sys.stdin).get("result") or []; print((r[0]["name"]+" "+r[0]["id"]) if r else "")') || true
        if [[ -z "$zone_name" || -z "$TUNNEL_ZONE_ID" ]]; then
            warn "CF API: TUNNEL_ZONE='${TUNNEL_ZONE}' not found or not active on this token — falling back to first active zone."
            zone_name=""
        fi
    fi
    if [[ -z "$zone_name" ]]; then
        read -r zone_name TUNNEL_ZONE_ID < <(curl -sf --max-time 15 -H "$auth" "$api/zones?status=active&order=name&direction=asc&per_page=1" \
            | python3 -c 'import json,sys; r=json.load(sys.stdin).get("result") or []; print((r[0]["name"]+" "+r[0]["id"]) if r else "")') || true
    fi
    if [[ -z "$zone_name" || -z "$TUNNEL_ZONE_ID" ]]; then
        warn "CF API: no active zone found (add a domain to Cloudflare + Zone:Read)"
        return 1
    fi

    TUNNEL_DOMAIN="${TUNNEL_NAME}.${zone_name}"
    log "Named hostname: ${TUNNEL_DOMAIN} (zone: ${zone_name})"
    return 0
}

# ─── Bootstrap named tunnel via CF API (CF_TOKEN only — no secrets) ───────
# Creates-or-reuses a tunnel named ${TUNNEL_NAME} and points TUNNEL_DOMAIN's
# DNS at it (CNAME → <tunnel-id>.cfargotunnel.com, proxied), all at boot time.
# Requires:
#   Account · Cloudflare Tunnel:Edit   (create tunnel + fetch token)
#   Zone    · Zone:Read + DNS:Edit     (find zone + create CNAME route)
# Precondition: resolve_named_host ran and set TUNNEL_DOMAIN/TUNNEL_ACCT_ID/
# TUNNEL_ZONE_ID. Returns 0 (ok) or 1 (fail → caller falls back to quick tunnel).
bootstrap_named_tunnel() {
    local api="https://api.cloudflare.com/client/v4"
    local auth="Authorization: Bearer ${CF_TOKEN}"
    local tunnel_id rec_id content tname

    log "Bootstrapping named tunnel '${TUNNEL_NAME}' for ${TUNNEL_DOMAIN} (CF API)..."
    tname="${TUNNEL_NAME}"   # fixed name → same tunnel every run (max 38 chars)

    # 1. Find-or-create the tunnel (Cloudflare Tunnel:Edit)
    tunnel_id=$(curl -sf --max-time 15 -H "$auth" "$api/accounts/${TUNNEL_ACCT_ID}/cfd_tunnel?name=${tname}" \
        | python3 -c 'import json,sys; r=json.load(sys.stdin).get("result") or []; print(r[0]["id"] if r else "")') || true
    if [[ -z "$tunnel_id" ]]; then
        log "Creating tunnel '${tname}'..."
        tunnel_id=$(curl -sf --max-time 15 -X POST -H "$auth" -H "Content-Type: application/json" \
            -d "{\"name\":\"${tname}\"}" "$api/accounts/${TUNNEL_ACCT_ID}/cfd_tunnel" \
            | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("result",{}).get("id","") if d.get("success") else "")') || true
        [[ -n "$tunnel_id" ]] || { warn "CF API: tunnel create failed (token lacks Cloudflare Tunnel:Edit?)"; return 1; }
    fi
    log "Named tunnel: ${tname} (${tunnel_id})"

    # 2. Fetch the tunnel connection token (Cloudflare Tunnel:Edit).
    #    NOTE: the API returns the token as a STRING in `result`
    #    ("result": "eyJhIj..." — a JWT), NOT as result.token. Handle both
    #    shapes so a plain string isn't mistaken for a permission failure.
    TUNNEL_TOKEN=$(curl -sf --max-time 15 -H "$auth" "$api/accounts/${TUNNEL_ACCT_ID}/cfd_tunnel/${tunnel_id}/token" \
        | python3 -c 'import json,sys
d=json.load(sys.stdin)
r=d.get("result") if d.get("success") else None
print(r if isinstance(r,str) else (r.get("token","") if isinstance(r,dict) else ""))') || true
    [[ -n "$TUNNEL_TOKEN" ]] || { warn "CF API: token fetch failed (token lacks Cloudflare Tunnel:Edit?)"; return 1; }

    # 3. DNS route: CNAME TUNNEL_DOMAIN → <tunnel-id>.cfargotunnel.com (proxied)
    #    (Zone:Read + DNS:Edit). Idempotent: reuse existing record if present.
    content="${tunnel_id}.cfargotunnel.com"
    rec_id=$(curl -sf --max-time 15 -H "$auth" "$api/zones/${TUNNEL_ZONE_ID}/dns_records?name=${TUNNEL_DOMAIN}&type=CNAME&per_page=1" \
        | python3 -c 'import json,sys; r=json.load(sys.stdin).get("result") or []; print(r[0]["id"] if r else "")') || true
    if [[ -n "$rec_id" ]]; then
        curl -sf --max-time 15 -X PATCH -H "$auth" -H "Content-Type: application/json" \
            -d "{\"content\":\"${content}\",\"proxied\":true}" \
            "$api/zones/${TUNNEL_ZONE_ID}/dns_records/${rec_id}" >/dev/null 2>&1 \
            && log "DNS route updated: ${TUNNEL_DOMAIN} → ${content}" \
            || { warn "CF API: DNS record update failed (token lacks DNS:Edit?)"; return 1; }
    else
        curl -sf --max-time 15 -X POST -H "$auth" -H "Content-Type: application/json" \
            -d "{\"type\":\"CNAME\",\"name\":\"${TUNNEL_DOMAIN}\",\"content\":\"${content}\",\"proxied\":true,\"ttl\":1}" \
            "$api/zones/${TUNNEL_ZONE_ID}/dns_records" >/dev/null 2>&1 \
            && log "DNS route created: ${TUNNEL_DOMAIN} → ${content}" \
            || { warn "CF API: DNS record create failed (token lacks DNS:Edit?)"; return 1; }
    fi

    return 0
}

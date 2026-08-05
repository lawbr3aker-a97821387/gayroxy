# 🇺🇳 Gayroxy — Multi-Protocol Proxy Suite

[![Deploy Proxy](https://github.com/USERNAME/gayroxy/actions/workflows/main.yml/badge.svg)](https://github.com/USERNAME/gayroxy/actions/workflows/main.yml)

**Self-hosted, multi-protocol proxy over Cloudflare Tunnel. Runs 24/7 on GitHub Actions for free.**

---

## 🌟 Features

| Protocol | Transport | TLS | Use Case |
|----------|-----------|-----|----------|
| VLESS / Trojan / VMess | WebSocket | ✅ | Browsers, mobile apps |
| VLESS / Trojan / VMess / Shadowsocks | gRPC | ✅ | HTTP/2 multiplexing |
| VLESS / Trojan / VMess | HTTPUpgrade | ✅ | Simpler than WS, works through nginx |
| Shadowsocks | Direct (local) | — | High performance |
| VLESS Reality | Direct (local) | — | Stealth, no cert needed |
| SOCKS5 / HTTP | Local | — | System proxy |

**Extra:**
- 🌍 **GeoIP/GeoSite databases** (Iran rules) served at `/geo/`
- 📱 **Web panel** at `/panel` with QR codes & config cards
- 🔗 **External subscription merging** — combine multiple subs into one
- 🛡️ **WARP integration** — Reddit traffic via residential IPs
- 🎲 **Stealth randomization** — each run varies timing & identity

---

## 🚀 Quick Start

### 1. Fork this repo

```bash
# Fork on GitHub, then:
git clone https://github.com/YOUR_USERNAME/gayroxy.git
cd gayroxy
```

### 2. Add GitHub Secrets

Go to **Settings → Secrets and variables → Actions → New repository secret**

| Secret | Required | Description |
|--------|:--------:|-------------|
| `CF_DOMAIN` | ✅ | Your Cloudflare domain (e.g. `proxy.example.com`) |
| `CF_AUTHTOKEN` | ✅ | Cloudflare API Token (Zone:Read, DNS:Edit) |
| `GH_TOKEN` | ✅ | GitHub Personal Access Token (repo + workflow scope) |
| `EXTERNAL_SUB_URLS` | ❌ | Comma-separated external subs to merge |

**How to get tokens:**

- **CF_AUTHTOKEN**: [Cloudflare Dashboard → My Profile → API Tokens](https://dash.cloudflare.com/profile/api-tokens) → Create Token → **Edit zone DNS** + **Zone Read**
- **GH_TOKEN**: [GitHub Settings → Developer settings → Personal access tokens → Fine-grained](https://github.com/settings/tokens) → Repository access: **This repo** → Permissions: **Contents (R/W), Actions (R/W), Workflows (R/W)**

### 3. Configure Cloudflare DNS

Add a **CNAME** record pointing to your tunnel (created automatically):

| Type | Name | Target | Proxy |
|------|------|--------|-------|
| CNAME | `proxy` | (auto-filled by tunnel) | 🟠 Proxied |

Or use a wildcard: `*.proxy.example.com`

### 4. Push & Deploy

```bash
git add -A
git commit -m "Initial deploy"
git push
```

The workflow runs immediately, sets up the tunnel, and re-triggers itself 24/7.

### 5. Access

| URL | Description |
|-----|-------------|
| `https://your-domain.com/sub` | Base64 subscription (merged) |
| `https://your-domain.com/panel` | Web panel with QR codes |
| `https://your-domain.com/geo/Country.mmdb` | GeoIP for Shadowrocket |
| `https://your-domain.com/geo/geoip.db` | GeoIP for NekoBox |
| `https://your-domain.com/geo/geosite.db` | GeoSite for NekoBox |

---

## ⚙️ Configuration

### Environment Variables (in workflow)

| Variable | Default | Description |
|----------|---------|-------------|
| `CF_DOMAIN` | — | **Required.** Your domain |
| `CF_AUTHTOKEN` | — | **Required.** CF API token |
| `EXTERNAL_SUB_URLS` | `""` | Comma-separated URLs to merge |
| `SEED` | `CF_AUTHTOKEN` | Deterministic UUID/password seed |
| `WARP_PORT` | `40000` | WARP SOCKS5 port |

### Customizing Protocols

Edit `proxy.sh` — paths, ports, and protocol list are at the top:

```bash
PORT_VLESS=10001
PATH_VLESS="/vless"
# ... etc
```

### Adding External Subscriptions

Set `EXTERNAL_SUB_URLS` secret:

```text
https://sub1.example.com/sub,https://sub2.example.com/sub,https://sub3.example.com/sub
```

The panel's **🔗 External Subs** tab shows all sources and merge status.

---

## 🔄 How It Works

```
┌─────────────────────────────────────────────────────────────────┐
│                      GITHUB ACTIONS (24/7)                       │
├─────────────────────────────────────────────────────────────────┤
│  1. Random delay (15–105s)                                      │
│  2. Checkout + install xray + cloudflared + WARP                │
│  3. Generate deterministic UUIDs/passwords from SEED            │
│  4. Start xray (13 protocols) + nginx                           │
│  5. Create Cloudflare Tunnel → your domain                      │
│  6. Fetch & merge external subscriptions                        │
│  7. Render /sub + /panel + /geo                                 │
│  8. Upload artifacts (3-day retention)                          │
│  9. Random delay (15–60s) → Re-trigger with random commit       │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│                      CLOUDFLARE EDGE                             │
├─────────────────────────────────────────────────────────────────┤
│  • TLS termination                                              │
│  • DDoS protection / WAF                                        │
│  • Routes WS/gRPC/HU to tunnel                                  │
│  • Serves static /sub, /panel, /geo                             │
└─────────────────────────────────────────────────────────────────┘
```

**Stealth features:**
- Each run has unique `workflow name` = `Build & Deploy <run_id>`
- Random startup + re-trigger delays (no fixed schedule)
- Random commit on re-trigger (looks like human activity)
- Short artifact retention (3 days)
- WARP routes Reddit via residential IPs

---

## 📱 Client Setup

### Shadowrocket (iOS)
1. Add subscription: `https://your-domain.com/sub`
2. **Settings → GeoLite2 数据库 → Country** → paste `https://your-domain.com/geo/Country.mmdb` → **更新**

### NekoBox (Android)
1. Import subscription
2. Download `geoip.db` + `geosite.db` from panel
3. **Menu → Import → Import from file** → select each .db

### V2RayNG / NekoRay / Sing-Box
- Import subscription URL directly
- Or copy individual links from panel

---

## 🛠️ Local Development

```bash
# Run locally (requires CF tokens)
CF_DOMAIN=proxy.example.com CF_AUTHTOKEN=xxx ./proxy.sh

# Test panel rendering
export DOMAIN=test.example.com
export SUB_B64=$(echo -n "vless://test" | base64 -w0)
export DATA='{}'
envsubst '${DATA} ${DOMAIN}' < templates/panel.html.tmpl > panel.html
```

---

## 🔐 Security Notes

- **All credentials are in GitHub Secrets** — never in code
- **Deterministic UUIDs** from `SEED` — same config on every deploy
- **Reality keys** generated fresh each run (ephemeral)
- **No persistent state** — runner is ephemeral
- **TLS terminated at Cloudflare edge** — no certs on runner

---

## ⚠️ Disclaimer

> This project is for **educational and personal use only**.
> Running proxy/circumvention services may violate GitHub ToS.
> Use at your own risk. The author is not responsible for
> any account suspensions, bans, or legal consequences.

**To minimize risk:**
- Use a dedicated GitHub account
- Enable 2FA on both GitHub & Cloudflare
- Monitor Actions usage (Settings → Billing)
- Consider moving to a VPS for production use

---

## 📄 License

MIT — Use freely, modify, distribute.

---

## 🙏 Credits

- [XTLS/Xray-core](https://github.com/XTLS/Xray-core) — Core proxy engine
- [cloudflare/cloudflared](https://github.com/cloudflare/cloudflared) — Tunnel client
- [Chocolate4U/Iran-v2ray-rules](https://github.com/Chocolate4U/Iran-v2ray-rules) — GeoIP rules
- [Chocolate4U/Iran-sing-box-rules](https://github.com/Chocolate4U/Iran-sing-box-rules) — GeoSite rules
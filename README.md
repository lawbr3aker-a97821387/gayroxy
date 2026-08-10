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

### 2. Add Secrets

Go to **Settings → Secrets and variables → Actions**.

| Secret | Required | Description |
|--------|:--------:|-------------|
| `CF_TOKEN` | ✅ | Cloudflare API token — **Workers Scripts:Edit**, **Workers KV Storage:Edit**, **Account Settings:Read** (see below) |
| `GH_TOKEN` | ❌ | GitHub PAT with `repo` + `workflow` scope. Optional — the built-in `GITHUB_TOKEN` works, but a PAT has higher rate limits and survives repo transfer. |
| `EXTERNAL_SUB_URLS` | ❌ | Comma-separated external subscription URLs to merge (unset → only the 15 built-in configs) |

> **That's it — two tokens max, one required.** No tunnel token, no tunnel
> domain. The proxy always runs in **quick-tunnel mode** (zero-config
> `trycloudflare.com` URL), and static assets are served from a **Cloudflare
> Worker + KV** you own, not GitHub Pages.

**Create `CF_TOKEN`** ([Cloudflare Dashboard → My Profile → API Tokens → Create Token](https://dash.cloudflare.com/profile/api-tokens)) with these permissions:

| Scope | Permission |
|-------|-----------|
| Account | Workers Scripts:Edit |
| Account | Workers KV Storage:Edit |
| Account | Account Settings:Read |
| Zone (optional) | Workers Routes:Edit — only if you want a **custom domain** for the panel/sub (see step 3) |

```bash
gh secret set CF_TOKEN        # paste the token
gh secret set GH_TOKEN        # optional PAT
```

### 3. (Optional) Custom domain for the panel/sub

By default everything is served at `https://gayroxy.<your-subdomain>.workers.dev`
(the exact URL is printed on every deploy and saved as the `WORKER_URL` repo
variable). To use your own domain, add a Cloudflare DNS record pointing at the
worker and set the repo variable:

```bash
gh variable set WORKER_ROUTE --body "sub.your-domain.com"
# then add a DNS CNAME:  sub → gayroxy.<subdomain>.workers.dev  (Proxied 🟠)
```

### 4. Push & Deploy

```bash
git add -A
git commit -m "Initial deploy"
git push
```

The workflow runs immediately: the render job publishes the static assets to
Cloudflare within ~2 minutes, the proxy job boots the tunnel, publishes the
live tunnel URL, and re-triggers itself 24/7.

### 5. Access

| URL | Description |
|-----|-------------|
| `https://gayroxy.<sub>.workers.dev/sub.txt` | Merged subscription (text/plain — opens in browser) |
| `https://gayroxy.<sub>.workers.dev/sub` | Merged subscription (base64 — for proxy clients) |
| `https://gayroxy.<sub>.workers.dev/panel` | Web panel with QR codes (always-on via Worker+KV) |
| `https://gayroxy.<sub>.workers.dev/geo/Country.mmdb` | GeoIP for Shadowrocket |
| `https://gayroxy.<sub>.workers.dev/geo/geoip.db` | GeoIP for NekoBox |
| `https://gayroxy.<sub>.workers.dev/geo/geosite.db` | GeoSite for NekoBox |

> **Note:** `/sub.txt` and `/sub` contain the same base64 subscription. `/sub.txt`
> is served as `text/plain` so it *displays* in a browser instead of downloading;
> proxy clients work with either URL (they ignore content-type). The panel is
> **host-agnostic** — it builds its own copyable URLs from wherever it's served.

> **Why `sub.txt` can look like gibberish:** it's a base64 blob of 15+ proxy
> config lines — that's what subscription clients expect. Paste it into your
> client (V2RayNG / NekoBox / Shadowrocket) via the **/sub** URL, don't read it
> as a web page.

---

## ⚙️ Configuration

### Environment Variables (in workflow)

| Variable | Default | Description |
|----------|---------|-------------|
| `CF_TOKEN` | — | **Required.** CF API token (Workers Scripts:Edit + Workers KV Storage:Edit + Account Settings:Read). Used to deploy the Worker + KV. Also the default `SEED`. |
| `EXTERNAL_SUB_URLS` | — (none) | Comma-separated external subscription URLs to merge into the panel. Unset → only the 15 built-in Gayroxy configs are served. |
| `WORKER_URL` | — | **Repo variable** (`vars.WORKER_URL`) — the Cloudflare Worker URL, saved automatically by `deploy-cf.sh` after the first deploy. |
| `WORKER_ROUTE` | — | **Repo variable** (optional) — custom domain for the Worker (e.g. `sub.example.com`); requires Zone Workers Routes:Edit + a DNS CNAME. |
| `SEED` | `CF_TOKEN` | Deterministic UUID/password seed — same seed = same configs on every deploy and from your laptop (`./update-assets.sh`). |
| `WARP_PORT` | `40000` | WARP SOCKS5 port |
| `RENDER_ONLY` | `0` | `1` = generate assets only (no xray/tunnel), used by CI render job |
| `REALITY_SNI` | `www.cloudflare.com` | Reality TLS fronting target (stealth) |
| `AUTO_RETRIGGER` | `0` | `1` = fire next run before 240-min cap + wait for old tunnel (zero-downtime handover); set by CI proxy job |
| `RUN_TIMEOUT_MIN` / `RETRIGGER_LEAD_MIN` | `240` / `8` | Auto-retrigger timing |
| `WATCHDOG_INTERVAL` / `WATCHDOG_FAILS` | `60` / `5` | Tunnel health watchdog (exit+restart after N failed checks) |

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
│  JOB 1 — render (fast, ~2 min, every run)                       │
│   RENDER_ONLY=1: generate sub + panel + geo                     │
│   → deploy-cf.sh: push assets to Cloudflare Worker + KV         │
│   → assets live within ~1 min of every push (no 240-min wait)   │
├─────────────────────────────────────────────────────────────────┤
│  JOB 2 — proxy (long-lived, up to 240 min)                      │
│  1. Checkout + install xray + cloudflared + WARP                │
│  2. Generate deterministic UUIDs/passwords from SEED            │
│  3. Start xray (13 protocols) + nginx                           │
│  4. Handover lock: wait for old tunnel to drop (~30s) → tunnel │
│  5. Create Cloudflare QUICK tunnel (random URL, no account)    │
│  6. Re-render /sub + /panel + /geo with the LIVE tunnel URL    │
│  7. deploy-cf.sh: publish live sub to Cloudflare KV (seconds)  │
│  8. Watchdog: health-check tunnel; auto-re-trigger next run    │
│     ~8 min before the 240-min cap (zero-downtime handover)     │
│  9. Final step re-dispatches on ANY outcome (if: always())     │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│                      CLOUDFLARE EDGE                             │
├─────────────────────────────────────────────────────────────────┤
│  • Worker + KV: serves /sub, /panel, /geo, /  — ALWAYS ON,      │
│    fast, independent of the runner (replaces GitHub Pages)       │
│  • Quick tunnel: routes WS/gRPC/HU to the live runner           │
└─────────────────────────────────────────────────────────────────┘
```

**CLOUDFLARE WORKER + KV (always-on, even when the runner is offline):**
- Serves `/panel`, `/sub.txt`, `/sub`, `/geo/*`, and `/` 24/7 from Workers KV
- Refreshed by Job 1 (`render`) on every run, and by Job 2 with the **live
  tunnel URL** seconds after the tunnel boots (quick-tunnel URL rotates every run)
- Deployed by `deploy-cf.sh` — needs only `CF_TOKEN` (self-discovers the
  account, creates the KV namespace, uploads assets + Worker)

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
# Full local run (quick tunnel, zero config)
./proxy.sh

# Render + deploy assets to Cloudflare from your laptop (no tunnel needed)
CF_TOKEN=xxx ./update-assets.sh
# Use the same SEED as CI so configs stay identical:
CF_TOKEN=xxx SEED=my-secret ./update-assets.sh

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
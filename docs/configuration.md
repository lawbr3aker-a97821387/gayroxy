# Configuration

This project is configured almost entirely through **environment variables**.
They are set in the GitHub Actions workflow (as Secrets / Variables) or inline
when running locally. Secrets (`CF_TOKEN`, `GH_TOKEN`, `SEED`) should never be
committed.

## Secrets (GitHub Secrets → env)

| Variable | Required | Purpose |
|---|---|---|
| `CF_TOKEN` | ✅ | Cloudflare API token. Scope: **Workers Scripts:Edit**, **Workers KV Storage:Edit**, **Account Settings:Read**. Add **Cloudflare Tunnel:Edit + Zone:Read + DNS:Edit** for the automatic named tunnel. |
| `GH_TOKEN` | ✅ | GitHub PAT with `repo` + `workflow`. Used by the auto-retrigger/keepalive dispatch. |
| `SEED` | strong rec. | Master secret. Everything (API token, all UUIDs/passwords, paths, Reality keys) is derived deterministically from it via `sha256`. Rotating it changes every client config. If unset, falls back to `CF_TOKEN`. |

## Workflow Variables (GitHub Variables → env)

| Variable | Default | Purpose |
|---|---|---|
| `EXTERNAL_SUB_URLS` | built-in source | Comma-separated external subscription URLs (panel-managed sources live in KV). |
| `WORKER_DOMAIN` | — | Custom hostname for the panel/sub (e.g. `sub.example.com`). |
| `WORKER_ROUTE` | — | Legacy custom-route domain, if used. |
| `TUNNEL_ZONE` | first active zone | Zone to host the automatic named tunnel. |

## Runtime tuning (workflow env)

Set these in the workflow's `env:` block to adjust behaviour without editing code:

| Variable | Default | Meaning |
|---|---|---|
| `RENDER_ONLY` | `0` | `1` = generate assets only (no xray/tunnel). Used by the render job. |
| `HEALTH_AGENT` | `0` | `1` = enable the external-sub health agent on serve. |
| `HEALTH_INTERVAL` | — | Seconds between health-agent pool re-checks. |
| `HEALTH_TIMEOUT` | — | Per-node probe timeout (s). |
| `SUBS_REFRESH_INTERVAL` | — | Seconds between refetching external source subscriptions. |
| `MAX_PER_SUB` / `BEST_PER_SUB` | — | Cap on external nodes kept per source. |
| `MAX_CONSEC_FAIL` | — | Consecutive failures before an external node is dropped. |
| `WATCHDOG_INTERVAL` | `20` | Seconds between tunnel liveness checks. |
| `WATCHDOG_FAILS` | `3` | Consecutive failed checks before the serve worker exits/restarts. |
| `AUTO_RETRIGGER` | `0` | `1` = fire next run before the 240-min cap (zero-downtime handover). |
| `RUN_TIMEOUT_MIN` | `240` | Max serve-job runtime before retrigger. |
| `RETRIGGER_LEAD_MIN` | `8` | How many minutes before `RUN_TIMEOUT_MIN` to fire the retrigger. |
| `BOOT_VERIFY_TIMEOUT` | — | Seconds the boot-verify job waits for `/sub` to be live. |
| `REALITY_SNI` | `www.cloudflare.com` | Reality TLS fronting target (stealth). |

## Local run

```bash
# Full serve (quick tunnel, zero config) — needs CF_TOKEN for named tunnel
CF_TOKEN=xxx ./scripts/serve.sh

# Render + deploy assets to Cloudflare from your laptop (no tunnel needed)
CF_TOKEN=xxx ./update-assets.sh
CF_TOKEN=xxx SEED=my-secret ./update-assets.sh   # lock SEED to match CI

# Interactive setup helper
./deploy.sh
```

## Derivation model

```
SEED ──sha256──► API_TOKEN, UUID_vless, UUID_vmess, UUID_reality,
                 TROJAN_PASS, SS_PASS, ports, paths, Reality keys
```

Because every client secret is a pure function of `SEED`, **rotating `SEED` is
the master kill-switch**: no stored credential table exists to leak.

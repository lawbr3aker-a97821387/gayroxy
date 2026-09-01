# Architecture

> Documented against the **current** repository layout. This is the real,
> delivered structure — if a script is listed below, it exists and passes
> `bash -n` + the render test.

## Runtime data plane

```
                    PUBLIC INTERNET
                    {  /sub, /panel  }
                          │
              ┌───────────┴───────────┐
              │      WORKER           │   ← Cloudflare Workers (KV-backed)
              └───────────┬───────────┘
                          │
              ┌───────────┴───────────┐
              │     CLOUDFLARE        │
              │  · Named Tunnel        │   ← DNS CNAME → tunnel.cfargotunnel
              │  · KV (sub + state)   │   ← API_TOKEN-protected writes
              └───────────┬───────────┘
                          │
         ┌────────────────┴────────────────┐
         │         GitHub Runner           │
         │  (serve job · 240-min timeout)  │
         │                                 │
         │  ┌───────────────────────────┐  │
         │  │         nginx :443         │  │  TLS termination + WS/gRPC reverse-proxy
         │  └───────────┬───────────────┘  │
         │              │                 │
         │  ┌───────────┴───────────┐      │
         │  │       xray-core        │     │   ← 13 inbounds on 127.0.0.1
         │  │                       │     │
         │  │         Inbounds       │     │     vless/trojan/vmess x {WS,gRPC,HU}
         │  │  ┌──────────┐         │     │     shadowsocks x3, reality, socks5, http
         │  │  └──────────┘         │     │
         │  │     Outbounds:        │     │
         │  │   "direct" → internet │     │
         │  │   "warp"   → CF WARP  │     │   (Reddit, geo-blocked)
         │  └───────────────────────┘     │
         │         ▲                     │
         │    ┌────┴────┐               │
         │    │ health  │               │
         │    │ agent   │               │   ← node pool, latency/country,
         │    │(aux xray)│              │     rotate2min, KV writes
         │    └─────────┘               │
         │         │                    │
         │    cloudflared(named tunnel)  │
         └────────────│──────────────────┘
                      │
              Client devices
              (v2ray / Nekoray / Streisand)
```

## Control plane

The deploy pipeline is split into **short-lived** jobs (render → publish,
weaned off `proxy.sh`) and a **long-lived** serve job. The serve job runs in a
separate workflow so it never blocks the deploy pipeline's concurrency group.

```
GitHub Push ──► main.yml
                 ├─ render         (fast · generate sub/panel/geo)
                 ├─ publish-live   (boot-verify + deploy to CF Worker/KV)
                 └─ serve          (long-lived · workflow_run on publish success)
                                        │
                                        ▼
                                   scripts/serve.sh
                                   boot xray + nginx + cloudflared
                                   health-agent (sub) · retrigger (auto-dispatch)
```

## Script map (real — matches the repo)

```
scripts/
├── serve.sh              ← live orchestrator: xray + nginx + tunnel + watchdog
├── lib/
│   ├── common.sh         ← shared exports, colors, logging, credential derivation
│   └── cloudflare.sh     ← CF API helpers + named-tunnel bootstrap
├── render/
│   └── build-assets.sh   ← templates → sub/, panel, geo (was the old RENDER_ONLY path)
├── publish/
│   ├── deploy-cf.sh      ← push assets (Worker + KV) — standalone
│   ├── publish-live.sh   ← re-render + deploy with the live tunnel URL
│   └── boot-verify.sh    ← probe the deployed /sub before marking boot verified
└── agent/
    └── health-agent.sh   ← external-sub health pool (independent aux xray)
```

Root `proxy.sh` was the former monolith; it has been **removed** and its
behaviour decomposed into the scripts above. Local convenience wrappers remain
(`deploy.sh` interactive setup, `update-assets.sh` laptop refresh) and call the
new `scripts/render/build-assets.sh` + `scripts/publish/deploy-cf.sh`.

## Credential derivation

Everything is derived from `SEED` (secret) + `sha256`. Nothing is stored raw:

```
SEED  →  derive_hex(32)  →  API_TOKEN     (bound to Worker env, used by publish + health-agent)
      →  UUID_vless_grpc → UUID_vmess → UUID_reality ...
      →  TROJAN_PASS, SS_PASS, paths, Reality keys
```

So rotating `SEED` is the master kill-switch for the entire account.

## Quality gates

`.github/workflows/ci.yml` runs on every push/PR and enforces:
- `bash -n` on every `scripts/**/*.sh` (syntax)
- `shellcheck -x` (static analysis)
- `shfmt` (formatting)
- `actionlint` (workflow validation)
- a template render test and a Worker syntax check

Run locally with `./tools/lint.sh`.

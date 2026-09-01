# Changelog

All notable changes to this project are documented here. Format loosely follows
[Keep a Changelog](https://keepachangelog.com/).

## [Unreleased]

### Changed
- Decomposed the monolithic `proxy.sh` into modular scripts:
  - `scripts/serve.sh` — long-lived orchestrator (xray + nginx + tunnel)
  - `scripts/render/build-assets.sh` — asset render phase (was `RENDER_ONLY`)
  - `scripts/publish/` — `deploy-cf.sh`, `publish-live.sh`, `boot-verify.sh`
  - `scripts/agent/health-agent.sh` — external-subscription health agent
  - `scripts/lib/` — shared constants (`common.sh`) + CF helpers (`cloudflare.sh`)
- Removed the legacy top-level `proxy.sh` monolith entirely.
- Added CI quality gates: `.github/workflows/ci.yml` (shellcheck, shfmt,
  actionlint, render test, Worker check) and `tools/lint.sh` for local use.
- Replaced the ASCII "How It Works" block in the README with mermaid diagrams.
- Added trust files: `LICENSE` (MIT), `SECURITY.md`, `CONTRIBUTING.md`.

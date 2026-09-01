# Contributing

Thanks for your interest! This repo is primarily an infrastructure project. A
few ground rules keep everything stable and reviewable.

## Workflow

1. **Fork** + create a feature branch (`git checkout -b feat/my-change`).
2. Make your change.
3. **Verify locally** before pushing:
   ```bash
   bash -n scripts/*.sh scripts/*/*.sh   # syntax
   shellcheck -x scripts/*.sh scripts/*/*.sh  # if you have shellcheck
   ```
4. Open a PR against `master`. CI (`.github/workflows/ci.yml`) will run
   shellcheck, shfmt, actionlint, a template render test, and the Worker check.

## Script conventions

- `bash` scripts use `set -euo pipefail`.
- Every script has a `--help` flag and a header comment explaining its role.
- Keep scripts **single-responsibility**. If a script grows past ~120 lines,
  consider extracting a leaf into `scripts/<domain>/`.
- Refer to the shared constants/helpers via
  `source "${SCRIPT_DIR}/scripts/lib/common.sh"` (and `cloudflare.sh`) — never
  duplicate them.
- Moving a script? Update **every** call site (workflows, other scripts, README,
  docs) and run `bash -n` + the render test. `git mv` preserves history.

## Style

- Shell: follow `shfmt` (`shfmt -i 2 -ci -bn`) and `shellcheck` (default rules).
- Docs/README: keep prose concise; use mermaid for diagrams (GitHub renders them).

## What not to do

- Do not commit secrets, tokens, or `SEED` values.
- Do not disable or weaken the CI gates to merge.
- Do not reintroduce a monolithic `proxy.sh` — the repo is intentionally
  decomposed into `scripts/`.

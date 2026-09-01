# Security Policy

## Reporting a Vulnerability

Please **do not** open a public GitHub issue for security vulnerabilities.

Send a private report instead:
- GitHub Security Advisories → **Report a vulnerability** on this repository
- Or email the maintainers privately

Include:
1. A clear description of the vulnerability
2. Steps to reproduce (proof of concept)
3. Impact assessment
4. Suggested fix, if you have one

## Scope

| In scope | Out of scope |
|---|---|
| The shell scripts under `scripts/` and root legacy tools | Third-party upstream dependencies |
| The Cloudflare Worker code (in `worker/`) | Host/IP reputation or abuse handling |
| Authentication token handling (`CF_TOKEN`, `GH_TOKEN`, `SEED`) | Anything requiring valid credentials (that's expected use) |

## Secrets & Keys

- `CF_TOKEN` (Cloudflare API) and `GH_TOKEN` (GitHub PAT) are **secrets** — never
  commit them, never put them in this repo, never log them in plaintext.
- The `SEED` derives all client credentials deterministically. If `SEED` is ever
  leaked, rotate it **and** regenerate all client configs (change `SEED`, then
  re-run `./scripts/render/build-assets.sh` + `./scripts/publish/deploy-cf.sh`).
- Tokens are scoped to the minimum permissions listed in the README.

## Supported

This is an actively-used personal/infra project. Security patches are applied on
the `master` branch as soon as practically possible after triage.

#!/usr/bin/env bash
# ─── deploy.sh ─────────────────────────────────────────────────────────────────
# Interactive first-time setup for Gayroxy.
#   • Verifies the repo is forked (not the upstream)
#   • Guides creation of GH_TOKEN (classic PAT, prefill URL) and CF_TOKEN
#   • Lists Cloudflare zones, lets user pick one for the stable named tunnel
#   • Writes secrets (CF_TOKEN, GH_TOKEN) and variables (WORKER_DOMAIN, TUNNEL_ZONE)
#   • Optionally runs a one-shot deploy to verify everything works
# ────────────────────────────────────────────────────────────────────────────────
set -euo pipefail

UPSTREAM_OWNER="lawbr3aker-a97821387"
UPSTREAM_REPO="gayroxy"
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Colors ─────────────────────────────────────────────────────────────────────
RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'; BLUE=$'\033[0;34m'; NC=$'\033[0m'
log()  { echo -e "${GREEN}[deploy]${NC} $*"; }
warn() { echo -e "${YELLOW}[deploy] WARNING${NC} $*"; }
err()  { echo -e "${RED}[deploy] ERROR${NC} $*" >&2; }
info() { echo -e "${BLUE}[deploy]${NC} $*"; }
ask()  { echo -ne "${BLUE}[deploy]${NC} $* "; read -r REPLY; echo; }

# ── 0. Prerequisites ───────────────────────────────────────────────────────────
command -v gh >/dev/null 2>&1 || { err "gh CLI not found. Install: https://cli.github.com/"; exit 1; }
command -v jq >/dev/null 2>&1 || { err "jq not found. Install: sudo apt-get install jq / brew install jq"; exit 1; }
command -v curl >/dev/null 2>&1 || { err "curl not found."; exit 1; }

log "Gayroxy Interactive Setup"
echo "────────────────────────────────────────────────────────────"

# ── 1. Fork check ──────────────────────────────────────────────────────────────
log "Checking if this repo is a fork (not the upstream)..."
ORIGIN_URL=$(git -C "$REPO_DIR" remote get-url origin 2>/dev/null || echo "")
if [[ -z "$ORIGIN_URL" ]]; then
    err "No 'origin' remote. Clone your fork first: gh repo fork $UPSTREAM_OWNER/$UPSTREAM_REPO --clone"
    exit 1
fi
# Extract owner/repo from origin URL (HTTPS or SSH)
if [[ "$ORIGIN_URL" =~ github\.com[:/]+([^/]+)/([^/.]+) ]]; then
    CURRENT_OWNER="${BASH_REMATCH[1]}"
    CURRENT_REPO="${BASH_REMATCH[2]}"
else
    err "Cannot parse origin URL: $ORIGIN_URL"
    exit 1
fi
if [[ "$CURRENT_OWNER" == "$UPSTREAM_OWNER" && "$CURRENT_REPO" == "$UPSTREAM_REPO" ]]; then
    err "This is the UPSTREAM repo. You MUST fork it first:"
    echo "  gh repo fork $UPSTREAM_OWNER/$UPSTREAM_REPO --clone"
    echo "  cd $UPSTREAM_REPO && ./deploy.sh"
    exit 1
fi
log "✓ Fork detected: $CURRENT_OWNER/$CURRENT_REPO"

# ── 2. gh auth check ───────────────────────────────────────────────────────────
log "Checking gh authentication..."
if ! gh auth status >/dev/null 2>&1; then
    err "gh is not authenticated. Run: gh auth login"
    exit 1
fi
GH_USER=$(gh api user -q .login)
log "✓ Authenticated as: @$GH_USER"
if [[ "$GH_USER" != "$CURRENT_OWNER" ]]; then
    warn "Authenticated user (@$GH_USER) ≠ repo owner ($CURRENT_OWNER)."
    warn "Secrets will be set on $CURRENT_OWNER/$CURRENT_REPO (requires admin/write access)."
fi

# ── 3. GH_TOKEN (GitHub PAT) ───────────────────────────────────────────────────
echo ""
info "═══  GH_TOKEN  (GitHub Personal Access Token)  ═══"
echo "Required scopes: repo, workflow"
echo "This token is used by the workflow to re-trigger the next run and"
echo "manage repo variables/secrets. A classic PAT is simplest."
echo ""
GH_TOKEN_URL="https://github.com/settings/tokens/new?scopes=repo,workflow&description=gayroxy-${CURRENT_REPO}"
info "Prefill URL (opens in browser):"
echo "  $GH_TOKEN_URL"
echo ""
ask "Paste your GH_TOKEN here (input hidden): "
read -rs GH_TOKEN
echo
if [[ -z "$GH_TOKEN" ]]; then
    err "GH_TOKEN cannot be empty."
    exit 1
fi
# Validate GH_TOKEN
if ! curl -sf -H "Authorization: Bearer $GH_TOKEN" "https://api.github.com/user" >/dev/null; then
    err "GH_TOKEN validation failed (401). Check the token."
    exit 1
fi
log "✓ GH_TOKEN validated"

# ── 4. CF_TOKEN (Cloudflare API Token) ─────────────────────────────────────────
echo ""
info "═══  CF_TOKEN  (Cloudflare API Token)  ═══"
echo "Cloudflare does NOT support prefill URLs. Create manually:"
echo "  1. Open: https://dash.cloudflare.com/profile/api-tokens"
echo "  2. Click 'Create Token' → 'Create Custom Token'"
echo "  3. Name: gayroxy-$CURRENT_REPO"
echo "  4. Permissions (REQUIRED for named tunnel + Worker deploy):"
echo "     • Account → Workers Scripts:Edit"
echo "     • Account → Workers KV Storage:Edit"
echo "     • Account → Account Settings:Read"
echo "     • Account → Cloudflare Tunnel:Edit"
echo "     • Zone → Zone:Read"
echo "     • Zone → DNS:Edit"
echo "     • Zone → Workers Routes:Edit (optional, for custom domain)"
echo "  5. Zone Resources: Include → All zones from account (or specific zone)"
echo "  6. Click 'Continue to summary' → 'Create Token'"
echo ""
info "Copy the token (shown only once)."
ask "Paste your CF_TOKEN here (input hidden): "
read -rs CF_TOKEN
echo
if [[ -z "$CF_TOKEN" ]]; then
    err "CF_TOKEN cannot be empty."
    exit 1
fi
# Validate CF_TOKEN and discover account + zones
log "Validating CF_TOKEN and discovering zones..."
CF_API="https://api.cloudflare.com/client/v4"
CF_AUTH="Authorization: Bearer $CF_TOKEN"

ACCOUNTS_RESP=$(curl -sf -H "$CF_AUTH" "$CF_API/accounts?per_page=50")
ACCOUNT_COUNT=$(echo "$ACCOUNTS_RESP" | jq '.result | length')
if [[ "$ACCOUNT_COUNT" -eq 0 ]]; then
    err "CF_TOKEN has no account access. Need 'Account Settings:Read' permission."
    exit 1
fi
ACCOUNT_ID=$(echo "$ACCOUNTS_RESP" | jq -r '.result[0].id')
ACCOUNT_NAME=$(echo "$ACCOUNTS_RESP" | jq -r '.result[0].name')
log "✓ Account: $ACCOUNT_NAME ($ACCOUNT_ID)"

# List active zones
ZONES_RESP=$(curl -sf -H "$CF_AUTH" "$CF_API/zones?status=active&per_page=100&order=name&direction=asc")
ZONE_COUNT=$(echo "$ZONES_RESP" | jq '.result | length')
if [[ "$ZONE_COUNT" -eq 0 ]]; then
    warn "No active zones found on this Cloudflare account."
    warn "You need to add a domain to Cloudflare (change nameservers) before the named tunnel can work."
    warn "The workflow will fall back to a random quick tunnel (trycloudflare.com) until a zone exists."
    SELECTED_ZONE=""
    SELECTED_ZONE_ID=""
else
    echo ""
    info "═══  Available Zones (for stable named tunnel)  ═══"
    echo "The named tunnel hostname will be: gaaayroxy.<zone>"
    echo ""
    echo "  #  Zone Name                    Zone ID"
    echo "  ──────────────────────────────────────────────────────"
    echo "$ZONES_RESP" | jq -r '.result[] | "\(.name)\t\(.id)"' | nl -w2 -s'. '
    echo "  ──────────────────────────────────────────────────────"
    echo "  A) Auto-pick first zone (alphabetical)"
    echo "  N) No zone — use quick tunnel (trycloudflare.com, rotates every run)"
    echo ""
    while true; do
        ask "Select zone [1-$ZONE_COUNT, A, N]: "
        choice="$REPLY"
        if [[ "$choice" =~ ^[1-9][0-9]*$ ]] && (( choice >= 1 && choice <= ZONE_COUNT )); then
            SELECTED_ZONE=$(echo "$ZONES_RESP" | jq -r ".result[$((choice-1))].name")
            SELECTED_ZONE_ID=$(echo "$ZONES_RESP" | jq -r ".result[$((choice-1))].id")
            log "Selected: $SELECTED_ZONE"
            break
        elif [[ "${choice^^}" == "A" ]]; then
            SELECTED_ZONE=$(echo "$ZONES_RESP" | jq -r '.result[0].name')
            SELECTED_ZONE_ID=$(echo "$ZONES_RESP" | jq -r '.result[0].id')
            log "Auto-selected first zone: $SELECTED_ZONE"
            break
        elif [[ "${choice^^}" == "N" ]]; then
            SELECTED_ZONE=""
            SELECTED_ZONE_ID=""
            warn "No zone selected — will use quick tunnel (random URL each run)."
            break
        else
            err "Invalid choice."
        fi
    done
fi

# ── 5. Optional: Custom Worker domain ──────────────────────────────────────────
echo ""
info "═══  Optional: Custom domain for the panel/sub (Workers Custom Domain)  ═══"
echo "By default, the panel/sub is at: https://gayroxy.<your-subdomain>.workers.dev"
echo "To use your own domain (e.g., proxy.example.com), it must be on the SAME"
echo "Cloudflare account (active zone). This creates a Workers Custom Domain with"
echo "auto-DNS + managed TLS (free plan supported)."
echo ""
ask "Set custom WORKER_DOMAIN? (e.g., proxy.example.com) [Enter to skip]: "
WORKER_DOMAIN="$REPLY"
if [[ -n "$WORKER_DOMAIN" ]]; then
    # Verify the domain's zone exists in the account
    ZONE_NAME="${WORKER_DOMAIN#*.}"
    ZONE_CHECK=$(curl -sf -H "$CF_AUTH" "$CF_API/zones?name=$ZONE_NAME&status=active&per_page=1")
    ZONE_ID=$(echo "$ZONE_CHECK" | jq -r '.result[0].id // empty')
    if [[ -z "$ZONE_ID" ]]; then
        warn "Zone '$ZONE_NAME' not found or not active on this account."
        warn "Custom domain will be skipped (can add later via: gh variable set WORKER_DOMAIN --body \"$WORKER_DOMAIN\")"
        WORKER_DOMAIN=""
    else
        log "✓ Zone for $WORKER_DOMAIN found: $ZONE_ID"
    fi
fi

# ── 6. Write secrets & variables ───────────────────────────────────────────────
echo ""
info "═══  Writing secrets and variables to GitHub  ═══"
log "Setting CF_TOKEN..."
gh secret set CF_TOKEN --repo "$CURRENT_OWNER/$CURRENT_REPO" --body "$CF_TOKEN" >/dev/null
log "Setting GH_TOKEN..."
gh secret set GH_TOKEN --repo "$CURRENT_OWNER/$CURRENT_REPO" --body "$GH_TOKEN" >/dev/null

if [[ -n "$SELECTED_ZONE" ]]; then
    log "Setting TUNNEL_ZONE variable: $SELECTED_ZONE"
    gh variable set TUNNEL_ZONE --repo "$CURRENT_OWNER/$CURRENT_REPO" --body "$SELECTED_ZONE" >/dev/null
fi
if [[ -n "$WORKER_DOMAIN" ]]; then
    log "Setting WORKER_DOMAIN variable: $WORKER_DOMAIN"
    gh variable set WORKER_DOMAIN --repo "$CURRENT_OWNER/$CURRENT_REPO" --body "$WORKER_DOMAIN" >/dev/null
fi
log "✓ All secrets/variables written."

# ── 7. Optional: One-shot verification deploy ──────────────────────────────────
echo ""
ask "Run a one-shot verification deploy now? (builds assets + pushes to Cloudflare) [y/N]: "
if [[ "${REPLY^^}" == "Y" ]]; then
    log "Running RENDER_ONLY + deploy-cf.sh locally..."
    cd "$REPO_DIR"
    RENDER_ONLY=1 CF_TOKEN="$CF_TOKEN" WORKER_URL="" ./scripts/render/build-assets.sh 2>&1 | tee logs/deploy-verify.log
    CF_TOKEN="$CF_TOKEN" ./scripts/publish/deploy-cf.sh 2>&1 | tee -a logs/deploy-verify.log
    log "Verification deploy complete. Check logs/deploy-verify.log"
fi

# ── 8. Summary ─────────────────────────────────────────────────────────────────
echo ""
info "═══  SETUP COMPLETE  ═══"
echo ""
echo "Configured:"
echo "  • Repo:           $CURRENT_OWNER/$CURRENT_REPO"
echo "  • GH_TOKEN:       ✓ (repo + workflow scopes)"
echo "  • CF_TOKEN:       ✓ (validated, account: $ACCOUNT_NAME)"
if [[ -n "$SELECTED_ZONE" ]]; then
    echo "  • TUNNEL_ZONE:    $SELECTED_ZONE  → hostname: gaaayroxy.$SELECTED_ZONE"
else
    echo "  • TUNNEL_ZONE:    (none) → will use quick tunnel (random URL)"
fi
if [[ -n "$WORKER_DOMAIN" ]]; then
    echo "  • WORKER_DOMAIN:  $WORKER_DOMAIN  (Workers Custom Domain)"
fi
echo ""
echo "Next steps:"
echo "  1. Push any local changes: git push origin main"
echo "  2. Trigger the workflow: gh workflow run 'Build & Deploy Proxy' -R $CURRENT_OWNER/$CURRENT_REPO"
echo "  3. Watch the run:        gh run watch -R $CURRENT_OWNER/$CURRENT_REPO"
echo ""
echo "The workflow will:"
echo "  • Render assets with the stable hostname (gaaayroxy.<zone>)"
echo "  • Deploy to Cloudflare Worker + KV"
echo "  • Boot the named tunnel (create-or-reuse) and point DNS at it"
echo "  • Publish the live sub.txt pointing at the static hostname"
echo ""
log "Done."
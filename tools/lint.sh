#!/usr/bin/env bash
# tools/lint.sh — repo-wide lint in one command.
# Locally: bash tools/lint.sh
# CI: same command (shellcheck gate is hard; shfmt gate is advisory).

set -euo pipefail
cd "$(dirname "$0")/.."

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
ok() { echo -e "${GREEN}✔${NC} $*"; }
warn() { echo -e "${YELLOW}!${NC} $*"; }
fail() { echo -e "${RED}✘${NC} $*"; }

EXIT=0

echo "── shellcheck ─────────────────────────────────────────"
if command -v shellcheck >/dev/null 2>&1; then
  if shellcheck -x --severity=warning $(find scripts -name '*.sh' -type f | sort); then
    ok "shellcheck clean"
  else
    fail "shellcheck issues"
    EXIT=1
  fi
else
  warn "shellcheck not installed — skipping (install: sudo apt install shellcheck)"
fi

echo ""
echo "── shfmt ──────────────────────────────────────────────"
if command -v shfmt >/dev/null 2>&1; then
  if shfmt -d -i 2 -ci -bn scripts/ 2>&1 | head -30; then
    [ -z "$(shfmt -d -i 2 -ci -bn scripts/ 2>/dev/null)" ] && ok "shfmt clean" || warn "shfmt differences (advisory)"
  fi
  :
else
  warn "shfmt not installed — skipping (go install mvdan.cc/sh/v3/cmd/shfmt@latest)"
fi

echo ""
echo "── bash -n syntax ─────────────────────────────────────"
SYNTAX_FAIL=0
for f in $(find scripts -name '*.sh' -type f | sort); do
  bash -n "$f" || { fail "$f failed bash -n"; SYNTAX_FAIL=1; }
done
[ "$SYNTAX_FAIL" = "0" ] && ok "bash -n all clean"

echo ""
echo "── actionlint ─────────────────────────────────────────"
if command -v actionlint >/dev/null 2>&1; then
  if actionlint; then
    ok "actionlint clean"
  else
    fail "actionlint issues"
    EXIT=1
  fi
else
  warn "actionlint not installed — skipping (go install github.com/rhysd/actionlint/cmd/actionlint@latest)"
fi

echo ""
if [ "$EXIT" = "0" ]; then
  echo -e "${GREEN}LINT PASS${NC}"
else
  echo -e "${RED}LINT FAIL${NC}"
fi
exit $EXIT

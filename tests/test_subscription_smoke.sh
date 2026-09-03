#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Extract only the normalise function; do not start the long-running agent.
awk 'NR>=151 && NR<=194 {print}' "$ROOT/scripts/agent/health-agent.sh" > "$TMP/normalise.sh"
# The extracted function expects its Python heredoc terminator and no runtime state.
source "$TMP/normalise.sh"

vless=$(normalise 'vless://11111111-1111-4111-8111-111111111111@example.com:443?type=ws&security=reality&sni=example.com&pbk=public&sid=abcd&fp=chrome&path=%2Fws#test')
python3 - "$vless" <<'PY'
import json,sys
x=json.loads(sys.argv[1])
assert x['_proto']=='vless' and x['host']=='example.com'
assert x['security']=='reality' and x['pbk']=='public' and x['sid']=='abcd'
PY

trojan=$(normalise 'trojan://secret@example.com:443?security=tls&sni=example.com#test')
python3 - "$trojan" <<'PY'
import json,sys
x=json.loads(sys.argv[1])
assert x['_proto']=='trojan' and x['user']=='secret' and x['port']==443
PY

ss=$(normalise 'ss://aes-256-gcm:password@example.com:8388#test')
python3 - "$ss" <<'PY'
import json,sys
x=json.loads(sys.argv[1])
assert x['_proto']=='ss' and x['method']=='aes-256-gcm' and x['user']=='password'
PY

vmess=$(normalise 'vmess://eyJhZGQiOiJleGFtcGxlLmNvbSIsInBvcnQiOiI0NDMiLCJpZCI6IjExMTExMTExLTExMTEtNDExMS04MTExLTExMTExMTExMTExMSIsIm5ldCI6IndzIiwidGxzIjoidGxzIiwicGF0aCI6Ii93cyJ9')
python3 - "$vmess" <<'PY'
import json,sys
x=json.loads(sys.argv[1])
assert x['_proto']=='vmess' and (x.get('host') or x.get('add'))=='example.com' and int(x['port'])==443
PY

echo 'subscription smoke tests passed'

auto="$(grep -c 'WARP_ASSIGN_LOCK=' "$ROOT/scripts/agent/health-agent.sh")"
[[ "$auto" -eq 1 ]]
grep -q 'current target during a' "$ROOT/scripts/agent/health-agent.sh"
grep -q 'reserved=0' "$ROOT/scripts/agent/health-agent.sh"

echo 'rotation guard tests passed'

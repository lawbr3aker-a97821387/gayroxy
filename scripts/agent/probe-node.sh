#!/usr/bin/env bash
# probe-node.sh — standalone node probe for parallel health checking.
# Called by health-agent.sh via xargs -P10.
# Exit 0 + stdout: latency_ms|country_code|node_json
# Exit 1: probe failed
#
# Env vars required: XRAY_BIN, AUX_DIR, AUX_LOG, HEALTH_TIMEOUT, PORT_BASE
set -uo pipefail
NODE="$1"
PORT=$(( PORT_BASE + $(printf '%s' "$NODE" | cksum | cut -d' ' -f1) % 1000 ))
CFG="$AUX_DIR/probe-$PORT.json"
LOGF="$AUX_LOG/probe-$PORT.log"

cleanup(){ rm -f "$CFG" "$LOGF"; }
trap cleanup EXIT

# Build xray outbound + config in Python (no parent functions needed)
python3 - "$NODE" "$CFG" "$PORT" <<'PY'
import sys,json
node,cfg_path,port = sys.argv[1],sys.argv[2],int(sys.argv[3])
x=json.loads(node)
proto=x['_proto']
host=x.get('host') or x.get('add')
port=int(x.get('port') or 443)
stream={'network':x.get('type') or 'tcp'}
if stream['network']=='ws':
    stream['wsSettings']={'path':x.get('path') or '/','headers':{'Host':host}}
elif stream['network']=='grpc':
    stream['grpcSettings']={'serviceName':x.get('serviceName') or ''}
elif stream['network']=='httpupgrade':
    stream['httpupgradeSettings']={'path':x.get('path') or '/','host':host}
sec=x.get('security') or ('tls' if x.get('tls') else '')
if sec in ('tls','reality'):
    stream['security']='tls'
    fp=x.get('fp') or ('chrome' if sec=='reality' else '')
    if sec=='reality':
        stream['tlsSettings']={'serverName':x.get('sni') or host,'fingerprint':fp or 'chrome',
            'realitySettings':{'publicKey':x.get('pbk') or '','shortId':x.get('sid') or '','serverName':x.get('sni') or host}}
    else:
        stream['tlsSettings']={'serverName':x.get('sni') or host,'fingerprint':fp or ''}
if proto=='vless':
    usr={'id':x.get('user',''),'encryption':'none'}
    flow=x.get('flow','')
    if not flow and sec=='reality': flow='xtls-rprx-vision'
    usr['flow']=flow
    ob={'tag':'node','protocol':'vless','settings':{'vnext':[{'address':host,'port':port,'users':[usr]}]},'streamSettings':stream}
elif proto=='vmess':
    ob={'tag':'node','protocol':'vmess','settings':{'vnext':[{'address':host,'port':port,'users':[{'id':x.get('id',''),'alterId':int(x.get('aid',0) or 0),'security':'auto'}]}]},'streamSettings':stream}
elif proto=='trojan':
    ob={'tag':'node','protocol':'trojan','settings':{'servers':[{'address':host,'port':port,'password':x.get('user','')}]},'streamSettings':stream}
else:
    ob={'tag':'node','protocol':'shadowsocks','settings':{'servers':[{'address':host,'port':port,'method':x.get('method','aes-256-gcm'),'password':x.get('user','')}]},'streamSettings':stream}
cfg={'log':{'loglevel':'error'},
     'inbounds':[{'tag':'in','listen':'127.0.0.1','port':port,'protocol':'socks','settings':{'udp':False}}],
     'outbounds':[ob,{'tag':'direct','protocol':'freedom'}],
     'routing':{'rules':[{'type':'field','inboundTag':['in'],'outboundTag':'node'}]}}
json.dump(cfg,open(cfg_path,'w'))
PY

# Run xray and probe through it
"$XRAY_BIN" run -c "$CFG" >"$LOGF" 2>&1 &
PID=$!
sleep .7

T=$(date +%s%N)
# Primary: ip-api.com (gives us exit-country + confirms routing)
RESULT=$(curl -fsS --max-time "$HEALTH_TIMEOUT" --proxy "socks5h://127.0.0.1:$PORT" \
    'http://ip-api.com/json?fields=countryCode' 2>/dev/null || true)
# Fallback: ipify (if ip-api.com blocks this egress IP)
[[ -z "$RESULT" ]] && RESULT=$(curl -fsS --max-time "$HEALTH_TIMEOUT" --proxy "socks5h://127.0.0.1:$PORT" \
    'https://api.ipify.org?format=json' 2>/dev/null || true)
ELAPSED=$(( ($(date +%s%N) - T) / 1000000 ))

kill "$PID" 2>/dev/null; wait "$PID" 2>/dev/null || true
[[ -z "$RESULT" ]] && exit 1

COUNTRY=$(printf '%s' "$RESULT" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("countryCode","??"))' 2>/dev/null || echo '??')
printf '%s|%s|%s\n' "$ELAPSED" "$COUNTRY" "$NODE"

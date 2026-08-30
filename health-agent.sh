#!/usr/bin/env bash
# External subscription health agent. It never edits or signals the main xray.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"
HEALTH_INTERVAL="${HEALTH_INTERVAL:-600}"
HEALTH_TIMEOUT="${HEALTH_TIMEOUT:-8}"
BEST_PER_SUB="${BEST_PER_SUB:-10}"
HEALTH_MAX_NODES="${HEALTH_MAX_NODES:-200}"
ROTATE2MIN_INTERVAL="${ROTATE2MIN_INTERVAL:-120}"
XRAY_BIN="${XRAY_BIN:-$ROOT/xray}"
DOMAIN="${DOMAIN:-tunnel-coming-on-first-run.trycloudflare.com}"
WORKER_URL="${WORKER_URL:-}"
API_TOKEN="${API_TOKEN:-}"
DEFAULT_EXTERNAL_SUB="${DEFAULT_EXTERNAL_SUB:-https://raw.githubusercontent.com/Kolandone/v2raycollector/main/config_lite.txt}"
SUB_DIR="${SUB_DIR:-$ROOT/sub}"
AUX_DIR="$ROOT/aux"
AUX_LOG="$ROOT/logs/aux"
POOL_FILE="$AUX_DIR/pool.tsv"
ROTATE_CONFIG="$AUX_DIR/rotate2min.json"
ROTATE_META="$AUX_DIR/rotate-meta.tsv"
ROTATE_STATE="$AUX_DIR/rotate-state.json"
ROTATE_PID=""
ONCE=0
[[ "${1:-}" == "--once" ]] && ONCE=1
mkdir -p "$AUX_DIR" "$AUX_LOG" "$SUB_DIR"

log(){ echo -e "\033[0;32m[health-agent]\033[0m $*"; }
warn(){ echo -e "\033[1;33m[health-agent] WARNING\033[0m $*"; }

cleanup(){ [[ -n "$ROTATE_PID" ]] && kill "$ROTATE_PID" 2>/dev/null || true; [[ -n "${AUX_ROTATE_PID:-}" ]] && kill "$AUX_ROTATE_PID" 2>/dev/null || true; }
trap cleanup INT TERM EXIT

fetch_sub(){
  local body
  body=$(curl -fsSL --max-time 20 --retry 1 "$1" 2>/dev/null || true)
  [[ -n "$body" ]] || return 1
  if ! printf '%s' "$body" | grep -qE '(^|[[:space:]])(vless|vmess|trojan|ss)://'; then
    body=$(printf '%s' "$body" | tr -d '\r\n ' | base64 -d 2>/dev/null || true)
  fi
  printf '%s\n' "$body" | grep -E '^(vless|vmess|trojan|ss)://' || true
}

# Normalise a link into JSON while preserving all credentials/settings.
normalise(){ python3 - "$1" <<'PY'
import sys,json,base64,urllib.parse,re
s=sys.argv[1].strip(); m=re.match(r'^(vless|vmess|trojan|ss)://(.+)$',s)
if not m: raise SystemExit(1)
p,rest=m.groups(); frag=''
if '#' in rest: rest,frag=rest.rsplit('#',1)
if p=='vmess':
 try: d=json.loads(base64.b64decode(rest+'='*((-len(rest))%4)))
 except Exception:
  # New v2rayN format: vmess://<uuid>@<host>:<port>?<query>#<frag> — no base64 blob.
  try:
   auth_rest,q=(rest.split('?',1) if '?' in rest else (rest,''))
   user,authority=auth_rest.rsplit('@',1)
   host,port=authority.rsplit(':',1)
  except Exception: raise SystemExit(1)
  params=urllib.parse.parse_qs(q)
  d={'_proto':'vmess','_remark':urllib.parse.unquote(frag),'host':host,'port':int(port),'id':user,'aid':0,
     'type':params.get('type',['tcp'])[0],'security':params.get('security',[''])[0],'tls':(params.get('security',[''])[0] if params.get('security',[''])[0] in ('tls','reality') else ''),
     'path':params.get('path',[''])[0],'sni':params.get('sni',[''])[0],
     'serviceName':params.get('serviceName',[''])[0],'method':params.get('method',['aes-256-gcm'])[0],
     'flow':params.get('flow',[''])[0],'pbk':params.get('pbk',[''])[0],'sid':params.get('sid',[''])[0]}
  print(json.dumps(d)); raise SystemExit
 d['_proto']='vmess'; d['_remark']=urllib.parse.unquote(frag); print(json.dumps(d)); raise SystemExit
q='';
if '?' in rest: rest,q=rest.split('?',1)
try:
 user,authority=rest.rsplit('@',1)
except ValueError: raise SystemExit(1)
if ':' not in authority: raise SystemExit(1)
host,port=authority.rsplit(':',1)
params=urllib.parse.parse_qs(q)
d={'_proto':p,'_remark':urllib.parse.unquote(frag),'host':host,'port':int(port),'user':urllib.parse.unquote(user),'type':params.get('type',['tcp'])[0],'security':params.get('security',[''])[0],'path':params.get('path',[''])[0],'sni':params.get('sni',[''])[0],'serviceName':params.get('serviceName',[''])[0],'method':params.get('method',['aes-256-gcm'])[0],'flow':params.get('flow',[''])[0],'pbk':params.get('pbk',[''])[0],'sid':params.get('sid',[''])[0]}
print(json.dumps(d))
PY
}

# Return xray outbound JSON for one normalised node.
outbound_json(){ python3 - "$1" <<'PY'
import sys,json,base64
x=json.loads(sys.argv[1]); p=x['_proto']; host=x.get('host') or x.get('add'); port=int(x.get('port') or 443)
stream={'network':x.get('type') or x.get('net') or 'tcp'}
if stream['network']=='ws': stream['wsSettings']={'path':x.get('path') or '/','headers':{'Host':x.get('host') or x.get('add')}}
elif stream['network']=='grpc': stream['grpcSettings']={'serviceName':x.get('serviceName') or x.get('path') or ''}
elif stream['network']=='httpupgrade': stream['httpupgradeSettings']={'path':x.get('path') or '/','host':host}
sec=x.get('security') or ('tls' if x.get('tls') else '')
if sec in ('tls','reality'):
 stream['security']='tls'; stream['tlsSettings']={'serverName':x.get('sni') or host,'fingerprint':x.get('fp') or ''}
 if x.get('pbk') and x.get('sid'):  # Reality: fallback SNI + short id
  stream['tlsSettings'].update({'fingerprint':x.get('fp') or 'chrome','serverName':x.get('sni') or x.get('host') or host,'realitySettings':{'publicKey':x.get('pbk'),'shortId':x.get('sid'),'serverName':x.get('sni') or x.get('host') or host}})
if p=='vless' and x.get('flow'): stream.setdefault('sockopt',{})['tcpFastOpen']=True
if p=='vmess':
  u=x.get('id',''); return_obj={'protocol':'vmess','settings':{'vnext':[{'address':host,'port':port,'users':[{'id':u,'alterId':int(x.get('aid',0) or 0),'security':'auto'}]}]},'streamSettings':stream}
elif p=='vless':
  return_obj={'protocol':'vless','settings':{'vnext':[{'address':host,'port':port,'users':[{'id':x.get('user',''),'encryption':'none'}]}]},'streamSettings':stream}
elif p=='trojan':
  return_obj={'protocol':'trojan','settings':{'servers':[{'address':host,'port':port,'password':x.get('user','')}]},'streamSettings':stream}
else:
  return_obj={'protocol':'shadowsocks','settings':{'servers':[{'address':host,'port':port,'method':x.get('method','aes-256-gcm'),'password':x.get('user','')}]},'streamSettings':stream}
print(json.dumps(return_obj,separators=(',',':')))
PY
}

# Test one node through a separate xray process. Output: latency|country|normalised-json.
test_node(){
  local node="$1" port="$2"
  local cfg="$AUX_DIR/test-$port.json" out="$AUX_LOG/test-$port.log"
  local ob; ob=$(outbound_json "$node") || return 1
  python3 - "$cfg" "$ob" "$port" <<'PY'
import sys,json
p,ob,port=sys.argv[1:]; o=json.loads(ob); o['tag']='node'
c={'log':{'loglevel':'error'},'inbounds':[{'tag':'in','listen':'127.0.0.1','port':int(port),'protocol':'socks','settings':{'udp':False}}],'outbounds':[o,{'tag':'direct','protocol':'freedom'}],'routing':{'rules':[{'type':'field','inboundTag':['in'],'outboundTag':'node'}]}}
json.dump(c,open(p,'w'))
PY
  "$XRAY_BIN" run -c "$cfg" >"$out" 2>&1 & local pid=$!
  sleep .7
  local t result country; t=$(date +%s%N)
  result=$(curl -fsS --max-time "$HEALTH_TIMEOUT" --proxy "socks5h://127.0.0.1:$port" 'http://ip-api.com/json?fields=countryCode' 2>/dev/null || true)
  local elapsed=$((($(date +%s%N)-t)/1000000))
  kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true
  [[ -n "$result" ]] || return 1
  country=$(printf '%s' "$result" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("countryCode","??"))' 2>/dev/null || echo '??')
  printf '%s|%s|%s\n' "$elapsed" "$country" "$node"
}

sub_name(){ python3 - "$1" <<'PY'
import sys,urllib.parse,re
u=urllib.parse.urlparse(sys.argv[1]); h=u.hostname or 'source'; print(re.sub(r'[^A-Za-z0-9._-]+','-',h)[:32])
PY
}

load_urls(){
  printf '%s\n' "$DEFAULT_EXTERNAL_SUB"
  [[ -n "${EXTERNAL_SUB_URLS:-}" ]] && printf '%s\n' "$EXTERNAL_SUB_URLS" | tr ',' '\n'
  if [[ -n "$WORKER_URL" ]]; then
    curl -fsSL --max-time 10 -H "x-gayroxy-token: $API_TOKEN" "$WORKER_URL/api/subs" 2>/dev/null | python3 -c 'import json,sys; print("\\n".join(json.load(sys.stdin).get("subs",[])))' 2>/dev/null || true
  fi
}

run_cycle(){
  : > "$POOL_FILE"
  local index=0 url name content line node result count
  declare -A seen=()
  while IFS= read -r url; do
    [[ -z "$url" || -n "${seen[$url]:-}" ]] && continue
    seen[$url]=1; name=$(sub_name "$url"); content=$(fetch_sub "$url" || true)
    [[ -n "$content" ]] || { warn "No nodes from $url"; continue; }
    local -a nodes=(); count=0
    while IFS= read -r line; do
      node=$(normalise "$line" 2>/dev/null || true); [[ -n "$node" ]] || continue
      nodes+=("$node"); count=$((count+1)); ((count >= HEALTH_MAX_NODES)) && break
    done <<< "$content"
    local -a good=(); local i=0
    for node in "${nodes[@]}"; do
      result=$(test_node "$node" $((21000+index)) || true); index=$((index+1))
      [[ -n "$result" ]] && good+=("$result")
    done
    if (( ${#good[@]} > 0 )); then
      printf '%s\n' "${good[@]}" | sort -t'|' -k1,1n | head -n "$BEST_PER_SUB" | while IFS='|' read -r latency country node; do
        printf '%s\t%s\t%s\t%s\n' "$name" "$latency" "$country" "$node" >> "$POOL_FILE"
      done
    fi
    log "$name: ${#good[@]} working; kept up to $BEST_PER_SUB"
  done < <(load_urls)
  write_health_json
  write_merged_sub
  write_rotate_config
}

write_health_json(){
  local rotate_state="${AUX_DIR}/rotate-state.json"
  local rotate_config="${AUX_DIR}/rotate2min.json"
  python3 - "$POOL_FILE" "$AUX_DIR/health.json" "$rotate_state" "$rotate_config" <<'PY'
import sys,json,datetime,collections,os
p,out,rs_path,rc_path=sys.argv[1:]
d=collections.defaultdict(list)
for line in open(p,errors='ignore'):
 parts=line.rstrip('\n').split('\t')
 if len(parts)==4: d[parts[0]].append({'latencyMs':int(parts[1]),'country':parts[2]})
rotation={}
if os.path.exists(rs_path):
 try: rotation=json.load(open(rs_path))
 except Exception: pass
rotation.setdefault('tag','')
rotation.setdefault('country','')
rotation.setdefault('host','')
rotation['algo']='rotate2min'
rotation['intervalSec']=int(os.environ.get('ROTATE2MIN_INTERVAL','120'))
if os.path.exists(rc_path):
 try:
  rc=json.load(open(rc_path))
  rotation['routingRule']=rc.get('routing',{}).get('rules',[{}])[0].get('outboundTag','')
 except Exception: pass
result={'checkedAt':datetime.datetime.utcnow().isoformat()+'Z','sources':d,'rotation':rotation}
json.dump(result,open(out,'w'),ensure_ascii=False,indent=2)
PY
  if [[ -n "$WORKER_URL" ]]; then
    curl -fsS --max-time 10 -X POST -H "Content-Type: application/json" -H "x-gayroxy-token: $API_TOKEN" --data-binary @"$AUX_DIR/health.json" "$WORKER_URL/api/health" >/dev/null 2>&1 || true
  fi
}

write_merged_sub(){
  [[ -s "${SUB_DIR}/subscription.b64" ]] || return 0
  local base; base=$(base64 -d "${SUB_DIR}/subscription.b64" 2>/dev/null || true)
  [[ -n "$base" ]] || return 0
  python3 - "$POOL_FILE" "$base" <<'PY' > "$SUB_DIR/external-healthy.txt"
import sys,json,urllib.parse
p,base=sys.argv[1:]; print(base)
flags=lambda c: ''.join(chr(127397+ord(x)) for x in c.upper()) if len(c)==2 else '🌐'
for line in open(p,errors='ignore'):
 a=line.rstrip('\n').split('\t');
 if len(a)!=4: continue
 sub,lat,c,node=a; x=json.loads(node); proto=x['_proto']; host=x.get('host') or x.get('add'); port=x.get('port',443); remark=f'Gayroxy-{flags(c)}-{sub}-{proto.upper()}-{host}'
 if proto=='vmess':
  x['ps']=remark; raw=json.dumps({k:v for k,v in x.items() if not k.startswith('_')},ensure_ascii=False).encode(); link='vmess://'+__import__('base64').b64encode(raw).decode()
 else:
  u=urllib.parse.quote(x.get('user',''),safe=''); q={'type':x.get('type','tcp'),'security':x.get('security','')}
  if x.get('path'): q['path']=x['path']
  if x.get('sni'): q['sni']=x['sni']
  if x.get('serviceName'): q['serviceName']=x['serviceName']
  query=urllib.parse.urlencode(q)
  scheme=proto; link=f'{scheme}://{u}@{host}:{port}?{query}#{urllib.parse.quote(remark)}'
 print(link)
PY
  cat "$SUB_DIR/external-healthy.txt" | base64 -w0 > "$SUB_DIR/subscription.b64"
}

write_rotate_config(){
  # Country of the runner itself (the main Gayroxy exit) for the pool-main entry.
  local main_country
  main_country=$(curl -fsS --max-time 5 'http://ip-api.com/json?fields=countryCode' 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin).get("countryCode","??"))' 2>/dev/null || echo '??')
  python3 - "$POOL_FILE" "$ROTATE_CONFIG" "$ROTATE_META" "${UUID_ROTATE2MIN:-}" "${PATH_ROTATE2MIN:-}" "$main_country" "${DOMAIN}" <<'PY'
import sys,json
pool,out,meta_path,uuid,path,main_country,main_host=sys.argv[1:]
obs=[]; meta=[]
# Main Gayroxy exit (this runner) is part of the rotation pool too.
meta.append('pool-main\t%s\t%s' % (main_country, main_host))
for n,line in enumerate(open(pool,errors='ignore')):
 a=line.rstrip('\n').split('\t')
 if len(a)!=4: continue
 try:
  x=json.loads(a[3]); p=x['_proto']; host=x.get('host') or x.get('add'); port=int(x.get('port') or 443)
  meta.append('pool-%d\t%s\t%s' % (n, a[2], host))
  stream={'network':x.get('type') or x.get('net') or 'tcp'}
  net=stream['network']
  if net=='ws': stream['wsSettings']={'path':x.get('path') or '/','headers':{'Host':host}}
  elif net=='grpc': stream['grpcSettings']={'serviceName':x.get('serviceName') or x.get('path') or ''}
  elif net=='httpupgrade': stream['httpupgradeSettings']={'path':x.get('path') or '/','host':host}
  if x.get('security')=='tls' or x.get('tls')=='tls': stream['security']='tls'; stream['tlsSettings']={'serverName':x.get('sni') or host,'fingerprint':x.get('fp') or 'chrome'}
  tag='pool-%d'%n
  if p=='vless': o={'tag':tag,'protocol':'vless','settings':{'vnext':[{'address':host,'port':port,'users':[{'id':x.get('user',''),'encryption':'none','flow':x.get('flow','')}]}]},'streamSettings':stream}
  elif p=='vmess': o={'tag':tag,'protocol':'vmess','settings':{'vnext':[{'address':host,'port':port,'users':[{'id':x.get('id',''),'alterId':int(x.get('aid',0) or 0),'security':'auto'}]}]},'streamSettings':stream}
  elif p=='trojan': o={'tag':tag,'protocol':'trojan','settings':{'servers':[{'address':host,'port':port,'password':x.get('user','')}]},'streamSettings':stream}
  elif p=='ss': o={'tag':tag,'protocol':'shadowsocks','settings':{'servers':[{'address':host,'port':port,'method':x.get('method','aes-256-gcm'),'password':x.get('user','')}]},'streamSettings':stream}
  else: continue
  obs.append(o)
 except Exception: pass
if not obs: obs=[{'tag':'pool-main','protocol':'freedom'}]
else: obs.append({'tag':'pool-main','protocol':'freedom'})
open(meta_path,'w').write('\n'.join(meta)+'\n')
first=next((o['tag'] for o in obs if o['tag'].startswith('pool-')),'pool-main')
c={'log':{'loglevel':'warning'},'inbounds':[{'tag':'rotate2min','listen':'127.0.0.1','port':10018,'protocol':'vless','settings':{'clients':[{'id':uuid}],'decryption':'none'},'streamSettings':{'network':'ws','security':'none','wsSettings':{'path':path}}}],'outbounds':obs,'routing':{'rules':[{'type':'field','inboundTag':['rotate2min'],'outboundTag':first}]}}
json.dump(c,open(out,'w'),indent=2)
PY
  if [[ -x "$XRAY_BIN" ]]; then
    [[ -n "${AUX_ROTATE_PID:-}" ]] && kill "$AUX_ROTATE_PID" 2>/dev/null || true
    "$XRAY_BIN" run -c "$ROTATE_CONFIG" >"$AUX_LOG/rotate2min.log" 2>&1 &
    AUX_ROTATE_PID=$!
    sleep .5
    kill -0 "$AUX_ROTATE_PID" 2>/dev/null || warn "aux rotate2min xray failed to start"
  else
    AUX_ROTATE_PID=""
    warn "aux rotate2min xray binary missing; skipping launch"
  fi
}

# Pick the next rotation target. Hard rule: never the same node twice in a row;
# prefer a different country AND a different host/datacenter, then relax step by step.
pick_next(){ python3 - "$ROTATE_META" "$ROTATE_STATE" <<'PY'
import json,sys,os,random
meta_path,state_path=sys.argv[1],sys.argv[2]
meta={}
for line in open(meta_path,errors='ignore'):
 a=line.rstrip('\n').split('\t')
 if len(a)==3: meta[a[0]]={'country':a[1],'host':a[2]}
if not meta: raise SystemExit(1)
state={}
if os.path.exists(state_path):
 try: state=json.load(open(state_path))
 except Exception: state={}
prev=state.get('tag'); pc=state.get('country'); ph=state.get('host')
tags=list(meta)
def pick(pred):
 c=[t for t in tags if t!=prev and pred(t)]
 return random.choice(c) if c else None
# 1) different country + different datacenter  2) different datacenter
# 3) any other node  4) single-node pool: keep current
t=pick(lambda x: meta[x]['country']!=pc and meta[x]['host']!=ph) \
 or pick(lambda x: meta[x]['host']!=ph) \
 or pick(lambda x: True)
if t is None: t=prev
sel=meta[t]
json.dump({'tag':t,'country':sel['country'],'host':sel['host']},open(state_path,'w'))
print(t)
PY
}

rotate_loop(){
  while :; do
    sleep "$ROTATE2MIN_INTERVAL"
    [[ -f "$ROTATE_CONFIG" && -f "$ROTATE_META" ]] || continue
    local next prev
    prev=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("routing",{}).get("rules",[{}])[0].get("outboundTag",""))' "$ROTATE_CONFIG" 2>/dev/null || true)
    next=$(pick_next 2>/dev/null || true)
    [[ -n "$next" ]] || continue
    [[ "$next" == "$prev" ]] && { log "Rotate 2min: single-node pool, keeping $next"; continue; }
    python3 - "$ROTATE_CONFIG" "$next" <<'PY'
import json,sys
p,tag=sys.argv[1:]; d=json.load(open(p)); d['routing']['rules'][0]['outboundTag']=tag; json.dump(d,open(p,'w'),indent=2)
PY
    # Restart only the aux xray so existing Rotate-2min connections migrate now.
    # The main Gayroxy xray is never touched.
    if [[ -n "${AUX_ROTATE_PID:-}" ]]; then kill "$AUX_ROTATE_PID" 2>/dev/null || true; fi
    if [[ -x "$XRAY_BIN" ]]; then
      "$XRAY_BIN" run -c "$ROTATE_CONFIG" >"$AUX_LOG/rotate2min.log" 2>&1 &
      AUX_ROTATE_PID=$!
    else
      AUX_ROTATE_PID=""
      warn "aux rotate2min xray binary missing; skipping restart"
      sleep "$ROTATE2MIN_INTERVAL"
      continue
    fi
    sleep .5
    kill -0 "$AUX_ROTATE_PID" 2>/dev/null || warn "aux rotate2min xray failed to restart"
    log "Rotate 2min -> $next (aux xray only)"
  done
}

main(){
  [[ -x "$XRAY_BIN" ]] || warn "xray binary not found; health checks will fail"
  run_cycle
  if (( ONCE == 1 )); then log "One health cycle complete"; return 0; fi
  rotate_loop & ROTATE_PID=$!
  while :; do sleep "$HEALTH_INTERVAL"; run_cycle; done
}
main

#!/usr/bin/env bash
# External subscription health agent. It never edits or signals the main xray.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"
# Health cycle: re-check the already-included pool every HEALTH_INTERVAL.
# Every SUBS_REFRESH_INTERVAL we also refetch the source subs and merge any
# newly-discovered working configs (replacing dead or outperformed ones only).
HEALTH_INTERVAL="${HEALTH_INTERVAL:-1200}"       # 20 min
SUBS_REFRESH_INTERVAL="${SUBS_REFRESH_INTERVAL:-7200}"  # 2 h
HEALTH_TIMEOUT="${HEALTH_TIMEOUT:-8}"
BEST_PER_SUB="${BEST_PER_SUB:-10}"
# Consecutive failed probes before a pooled node is dropped from rotation.
MAX_CONSEC_FAIL="${MAX_CONSEC_FAIL:-3}"
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
POOL_STATE="$AUX_DIR/pool-state.json"   # per-node consecutive failure / last-seen tracking
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
  if ! [[ "$body" == *'vless://'* || "$body" == *'vmess://'* || "$body" == *'trojan://'* || "$body" == *'ss://'* ]]; then
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
     'path':params.get('path',[''])[0],'sni':params.get('sni',[''])[0],'fp':params.get('fp',[''])[0],
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
d={'_proto':p,'_remark':urllib.parse.unquote(frag),'host':host,'port':int(port),'user':urllib.parse.unquote(user),'type':params.get('type',['tcp'])[0],'security':params.get('security',[''])[0],'path':params.get('path',[''])[0],'sni':params.get('sni',[''])[0],'fp':params.get('fp',[''])[0],'serviceName':params.get('serviceName',[''])[0],'method':params.get('method',['aes-256-gcm'])[0],'flow':params.get('flow',[''])[0],'pbk':params.get('pbk',[''])[0],'sid':params.get('sid',[''])[0]}
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
    stream['security']='tls'
    fp=x.get('fp') or ('chrome' if sec=='reality' else '')
    if sec=='reality':
        # Reality: fingerprint + publicKey + shortId + serverName are mandatory
        stream['tlsSettings']={'serverName':x.get('sni') or host,'fingerprint':fp or 'chrome','realitySettings':{'publicKey':x.get('pbk') or '','shortId':x.get('sid') or '','serverName':x.get('sni') or host}}
    else:
        stream['tlsSettings']={'serverName':x.get('sni') or host,'fingerprint':fp or ''}
if p=='vless':
    usr={'id':x.get('user',''),'encryption':'none'}
    if x.get('flow'): usr['flow']=x.get('flow')          # reality+vision requires flow on the user
    elif sec=='reality': usr['flow']='xtls-rprx-vision'  # reality w/o explicit flow: default vision
    return_obj={'protocol':'vless','settings':{'vnext':[{'address':host,'port':port,'users':[usr]}]},'streamSettings':stream}
elif p=='vmess':
    u=x.get('id',''); return_obj={'protocol':'vmess','settings':{'vnext':[{'address':host,'port':port,'users':[{'id':u,'alterId':int(x.get('aid',0) or 0),'security':'auto'}]}]},'streamSettings':stream}
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
  # Primary probe through the node; fall back to a second endpoint so a
  # single blocked geo-API cannot reject every config (runner egress varies).
  result=$(curl -fsS --max-time "$HEALTH_TIMEOUT" --proxy "socks5h://127.0.0.1:$port" 'http://ip-api.com/json?fields=countryCode' 2>/dev/null || true)
  [[ -n "$result" ]] || result=$(curl -fsS --max-time "$HEALTH_TIMEOUT" --proxy "socks5h://127.0.0.1:$port" 'https://api.ipify.org?format=json' 2>/dev/null || true)
  local elapsed=$((($(date +%s%N)-t)/1000000))
  kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true
  [[ -n "$result" ]] || return 1
  country=$(printf '%s' "$result" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("countryCode","??"))' 2>/dev/null || echo '??')
  printf '%s|%s|%s\n' "$elapsed" "$country" "$node"
}

# Fast TCP pre-filter: connect to host:port with a short timeout. Cheaper than
# booting xray for every candidate — a dead port is skipped before the full
# tunnel test. Only nodes whose port accepts a connection proceed to test_node.
# NOTE: this is a cheap heuristic only; the authoritative "config is alive"
# check is test_node's full xray->socks->HTTP round trip, so a false positive
# here can never leak a dead config into the pool.
tcp_ping(){
  local node="$1" host port
  host=$(printf '%s' "$node" | python3 -c 'import sys,json; x=json.load(sys.stdin); print(x.get("host") or x.get("add") or "")' 2>/dev/null) || return 1
  port=$(printf '%s' "$node" | python3 -c 'import sys,json; x=json.load(sys.stdin); print(int(x.get("port") or 443))' 2>/dev/null) || return 1
  [[ -n "$host" ]] || return 1
  if command -v nc >/dev/null 2>&1; then
    timeout 4 nc -z -w2 "$host" "$port" 2>/dev/null
  else
    # Fallback: bash /dev/tcp (reports success on hung SYN — nc is preferred)
    timeout 3 bash -c "exec 3<>/dev/tcp/$host/$port" 2>/dev/null
  fi
}

sub_name(){ python3 - "$1" <<'PY'
import sys,urllib.parse,re
u=urllib.parse.urlparse(sys.argv[1]); h=u.hostname or 'source'; print(re.sub(r'[^A-Za-z0-9._-]+','-',h)[:32])
PY
}

load_urls(){
  # Match proxy.sh semantics: the built-in DEFAULT_EXTERNAL_SUB is used ONLY
  # when the user has not supplied their own EXTERNAL_SUB_URLS. If they have,
  # use exactly those — otherwise the default always gets merged in on top and
  # the user's machine ends up with far more than BEST_PER_SUB nodes per sub.
  #
  # The worker's /api/subs KV list is NOT consulted here. That store can hold
  # up to MAX_SUBS=20 subs accumulated over time; pulling them all in would
  # merge dozens of unrelated sources and blow past the BEST_PER_SUB cap per
  # user-supplied sub. The source list is explicitly EXTERNAL_SUB_URLS only.
  if [[ -z "${EXTERNAL_SUB_URLS:-}" ]]; then
    printf '%s\n' "$DEFAULT_EXTERNAL_SUB"
  else
    printf '%s\n' "$EXTERNAL_SUB_URLS" | tr ',' '\n'
  fi
}

# Re-test only the currently-included pool (no source refetch). Runs every
# HEALTH_INTERVAL (default 20 min). Updates per-node latency/country and drops
# a node only after MAX_CONSEC_FAIL consecutive failed probes — so a transient
# blip never yanks a working config out of rotation.
health_only(){
  [[ -s "$POOL_FILE" ]] || { log "pool empty; waiting for a source refresh"; return 0; }
  local -a kept=() rej=()
  local port=$((21000))
  while IFS=$'\t' read -r name latency country node; do
    [[ -n "$name" && -n "$node" ]] || continue
    local res
    res=$(test_node "$node" "$port" || true); port=$((port+1))
    if [[ -n "$res" ]]; then
      # latest latency|country from the live probe; keep name + node as-is
      local nl nc
      IFS='|' read -r nl nc _ <<< "$res"
      kept+=("$name|$nl|$nc|$node")
      update_state "$node" 0
    else
      if bump_fail "$node"; then
        rej+=("$name|$node")
      else
        # Not yet at the drop threshold — keep it one more cycle (don't interrupt).
        kept+=("$name|$latency|$country|$node")
      fi
    fi
  done < "$POOL_FILE"
  : > "$POOL_FILE"
  for row in "${kept[@]}"; do
    IFS='|' read -r name lat c node <<< "$row"
    printf '%s\t%s\t%s\t%s\n' "$name" "$lat" "$c" "$node" >> "$POOL_FILE"
  done
  for row in "${rej[@]}"; do IFS='|' read -r name node <<< "$row"; log "dropped (${MAX_CONSEC_FAIL} consecutive fails): $name ${node:0:40}"; done
  log "health pass: ${#kept[@]} remain in pool"
  finalize
}

# Refetch every external sub, health-test a fresh batch of candidates, and merge
# the results into the pool — keeping the currently-working nodes and only
# swapping in newly-found working configs when they beat (or replace) a worse
# or dead one. Per sub we hold at most BEST_PER_SUB configs, ordered by latency.
refresh_sources(){
  local -a kept=()
  local index=0 url name content line node result
  declare -A seen=()
  # Seed with every currently-active pool row so a source that is briefly
  # unreachable never wipes the working set. (5th field = existing flag)
  if [[ -s "$POOL_FILE" ]]; then
    while IFS=$'\t' read -r name latency country node; do
      [[ -n "$name" && -n "$node" ]] && kept+=("$name|$latency|$country|$node|1")
    done < "$POOL_FILE"
  fi
  while IFS= read -r url; do
    [[ -z "$url" || -n "${seen[$url]:-}" ]] && continue
    seen[$url]=1; name=$(sub_name "$url")
    content=$(fetch_sub "$url" || true)
    [[ -n "$content" ]] || { warn "No nodes from $url (keeping existing pool)"; continue; }
    local -a nodes=() good=()
    while IFS= read -r line; do
      node=$(normalise "$line" 2>/dev/null || true); [[ -n "$node" ]] || continue
      nodes+=("$node")
      (( ${#nodes[@]} >= 120 )) && break
    done <<< "$content"
    for node in "${nodes[@]}"; do
      # Fast TCP pre-filter: skip dead hosts before the expensive xray probe.
      tcp_ping "$node" || continue
      # STRICT gate: only a full tunnel test (real xray through the node)
      # qualifies. A TCP-alive-but-full-test-failed node is dropped — it is not
      # proven to carry traffic and would only waste a slot in the user's sub.
      result=$(test_node "$node" $((22000+index)) || true); index=$((index+1))
      [[ -n "$result" ]] && good+=("$result")
    done
    # Add this sub's new working candidates to the merge list.
    for r in "${good[@]}"; do kept+=("$name|$r|0"); done
    log "$name: ${#good[@]} fresh working candidates (pool merge keeps up to $BEST_PER_SUB/sub)"
  done < <(load_urls)
  # Write candidate rows to a temp file and let select_pool read it (a heredoc
  # owns python stdin, so data must travel by file, not pipe).
  local cand="$AUX_DIR/.merge-cands.tsv"
  printf '%s\n' "${kept[@]}" > "$cand"
  select_pool "$cand"
  rm -f "$cand"
  finalize
}

# Merge all rows (existing pool first, then fresh candidates), then per sub keep
# the BEST_PER_SUB fastest working configs. Existing active nodes win latency
# ties so we don't churn a working exit for an equal one.
select_pool(){
  python3 - "$POOL_FILE" "$BEST_PER_SUB" "$1" <<'PY'
import sys,collections
p,limit,cand=sys.argv[1],int(sys.argv[2]),sys.argv[3]
subs=collections.defaultdict(list)
for line in open(cand,errors='ignore'):
 if not line.strip(): continue
 a=line.rstrip('\n').split('|')
 if len(a)!=4 and len(a)!=5: continue
 if len(a)==5:
  sub,lat,country,node,existing=a
 else:
  sub,lat,country,node=a; existing='0'
 subs[sub].append((int(lat), country, node, int(existing)))
out=[]
for sub,entries in subs.items():
 # sort by (latency, prefer-existing) => existing wins ties
 entries.sort(key=lambda r:(r[0], 0 if r[3] else 1))
 # Dedupe by host (ignoring port) so one server can't fill several slots.
 seen_hosts=set(); keep=[]
 for lat,country,node,existing in entries:
  try:
   import json as _j
   host=_j.loads(node).get('host') or _j.loads(node).get('add')
  except Exception:
   host=None
  if host:
   hk=host.lower()
   if hk in seen_hosts: continue
   seen_hosts.add(hk)
  keep.append((lat,country,node))
 for lat,country,node in keep[:limit]:
  out.append((sub,lat,country,node))
with open(p,'w') as f:
 for sub,lat,country,node in out:
  f.write('%s\t%s\t%s\t%s\n'%(sub,lat,country,node))
print('pool:',len(out),'configs across',len(subs),'subs')
PY
}

# Persist/read consecutive-failure counters for pooled nodes.
update_state(){ python3 - "$POOL_STATE" "$1" "$2" <<'PY'
import sys,json,os
p,node,ok=sys.argv[1],sys.argv[2],sys.argv[3]
st={}
if os.path.exists(p):
 try: st=json.load(open(p))
 except Exception: pass
k=node[:80]
st.setdefault(k,{'fails':0})
st[k]['fails']=0 if ok=='0' else st[k].get('fails',0)+1
json.dump(st,open(p,'w'))
PY
}
bump_fail(){ python3 - "$POOL_STATE" "$1" "$MAX_CONSEC_FAIL" <<'PY' | grep -q '^1$'
import sys,json,os
p,node,lim=sys.argv[1],sys.argv[2],int(sys.argv[3])
st={}
if os.path.exists(p):
 try: st=json.load(open(p))
 except Exception: pass
k=node[:80]; f=st.get(k,{}).get('fails',0)+1
print('1' if f>=lim else '0')
st[k]={'fails':f}
json.dump(st,open(p,'w'))
PY
}

finalize(){ write_health_json; write_merged_sub; write_rotate_config; }

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
  # Build the final public subscription: the Gayroxy-native configs from the
  # current subscription PLUS the health agent's capped (BEST_PER_SUB/sub)
  # external pool. Any previously-merged "External-*" links are dropped so a
  # stale uncapped external section never leaks back in.
  python3 - "$POOL_FILE" "$base" <<'PY' > "$SUB_DIR/external-healthy.txt"
import sys,json,urllib.parse,base64,re
p,b64=sys.argv[1:]
lines=[l for l in b64.split('\n') if l.strip()]
def is_external(line):
    if '#' in line:
        frag=line.rsplit('#',1)[1]
        if frag.startswith('External-'): return True
    m=re.match(r'^vmess://(.+)$',line)
    if m:
        try:
            d=json.loads(base64.b64decode(m.group(1)+'='*((-len(m.group(1)))%4)))
            if str(d.get('ps','')).startswith('External-'): return True
        except Exception: pass
    return False
flags=lambda c: ''.join(chr(127397+ord(x)) for x in c.upper()) if len(c)==2 else '🌐'
for line in lines:
    if not is_external(line):
        print(line)
for line in open(p,errors='ignore'):
 a=line.rstrip('\n').split('\t');
 if len(a)!=4: continue
 sub,lat,c,node=a; x=json.loads(node); proto=x['_proto']; host=x.get('host') or x.get('add'); port=x.get('port',443); remark=f'Gayroxy-{flags(c)}-{sub}-{proto.upper()}-{host}'
 if proto=='vmess':
  x['ps']=remark; raw=json.dumps({k:v for k,v in x.items() if not k.startswith('_')},ensure_ascii=False).encode(); link='vmess://'+base64.b64encode(raw).decode()
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
  push_sub
}

# Push the freshly-merged public subscription to the Worker KV so /sub reflects
# the health agent's capped external pool (deploy-cf.sh only uploads at render
# time; without this the served sub never updates after boot).
push_sub(){
  [[ -s "$SUB_DIR/subscription.b64" ]] || return 0
  [[ -n "${WORKER_URL:-}" ]] || return 0
  curl -fsS --max-time 10 -X POST \
    -H "Content-Type: text/plain; charset=utf-8" \
    -H "x-gayroxy-token: ${API_TOKEN:-}" \
    --data-binary @"$SUB_DIR/subscription.b64" \
    "$WORKER_URL/api/sub" >/dev/null 2>&1 \
    && log "Pushed merged subscription to KV" 2>/dev/null || true
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
  # First run: full source refresh so the pool is populated and the merged
  # sub / rotate config are written before any rotation happens.
  refresh_sources
  if (( ONCE == 1 )); then log "One health cycle complete"; return 0; fi
  rotate_loop & ROTATE_PID=$!
  # Two-tier scheduler:
  #  - every HEALTH_INTERVAL (20 min): re-health the included pool only
  #  - every SUBS_REFRESH_INTERVAL (2 h): refetch sources and merge new configs
  local elapsed=0
  while :; do
    sleep "$HEALTH_INTERVAL"; elapsed=$((elapsed + HEALTH_INTERVAL))
    if (( elapsed >= SUBS_REFRESH_INTERVAL )); then
      refresh_sources; elapsed=0
    else
      health_only
    fi
  done
}
main

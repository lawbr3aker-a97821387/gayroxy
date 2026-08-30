// ─── Gayroxy static asset server — Cloudflare Worker backed by Workers KV ───
// Serves the always-on assets (subscription, panel, geo databases) that used
// to live on GitHub Pages. KV values are written by deploy-cf.sh on every run.
// Host-agnostic: works on *.workers.dev, a custom route, or anywhere else the
// script is deployed — the panel builds its own absolute URLs from location.origin.

const CONTENT_TYPES = {
  '.html': 'text/html; charset=utf-8',
  '.htm': 'text/html; charset=utf-8',
  '.txt': 'text/plain; charset=utf-8',
  '.b64': 'text/plain; charset=utf-8',
  '.dat': 'application/octet-stream',
  '.db': 'application/octet-stream',
  '.mmdb': 'application/octet-stream',
  '.json': 'application/json; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.js': 'application/javascript; charset=utf-8',
  '.svg': 'image/svg+xml',
  '.png': 'image/png',
  '.ico': 'image/x-icon',
  '.woff2': 'font/woff2',
};

// Map request paths to KV keys, mirroring the old GitHub Pages layout so
// existing bookmarks/links keep working:
//   /            → index.html
//   /sub, /sub.txt, /subscription.b64 → subscription file
//   /panel, /panel.html               → panel.html
//   /geo/<file>                       → geo/<file>
function resolveKey(pathname) {
  let p = pathname;
  if (p.endsWith('/')) p += 'index.html';
  if (p === '/') return 'index.html';
  const key = p.replace(/^\/+/, '');
  if (key === 'sub') return 'sub.txt';
  if (key === 'sub.b64' || key === 'subscription.b64') return 'subscription.b64';
  if (key === 'panel') return 'panel.html';
  return key;
}

function contentType(key) {
  const dot = key.lastIndexOf('.');
  const ext = dot >= 0 ? key.slice(dot).toLowerCase() : '';
  return CONTENT_TYPES[ext] || 'application/octet-stream';
}

// Binary files must be read as ArrayBuffer; everything else as text.
function isBinary(key) {
  return /\.(dat|db|mmdb|png|ico|woff2?)$/i.test(key);
}

// ─── Panel-managed external subscriptions API ────────────────────────────────
// KV key "external_subs" holds a JSON array of subscription URLs added from the
// web panel. Light auth: the panel sends the shared token derived from SEED.
const SUBS_KEY = 'external_subs';
const MAX_SUBS = 20;

function json(data, status = 200) {
  return new Response(JSON.stringify(data), {
    status,
    headers: { 'content-type': 'application/json; charset=utf-8' },
  });
}

function validUrl(u) {
  try {
    const parsed = new URL(u);
    return parsed.protocol === 'http:' || parsed.protocol === 'https:';
  } catch {
    return false;
  }
}

async function getSubs(env) {
  const raw = await env.ASSETS.get(SUBS_KEY);
  if (!raw) return [];
  try {
    const list = JSON.parse(raw);
    return Array.isArray(list) ? list.filter((u) => typeof u === 'string') : [];
  } catch {
    return [];
  }
}

async function putSubs(env, subs) {
  await env.ASSETS.put(SUBS_KEY, JSON.stringify(subs));
}

async function handleSubs(request, env) {
  const url = new URL(request.url);
  const token = request.headers.get('x-gayroxy-token') || url.searchParams.get('token') || '';
  // When an expected token binding exists, enforce it on every method. Without
  // a binding, writes require any non-empty token (defense-in-depth) while
  // GET stays open so the panel can list sources without secrets.
  const expect = env.API_TOKEN || '';
  if (expect && token !== expect) {
    return json({ error: 'unauthorized' }, 401);
  }

  if (request.method === 'GET') {
    return json({ subs: await getSubs(env) });
  }

  if (request.method === 'POST') {
    if (!token) return json({ error: 'missing token' }, 401);
    let body;
    try {
      body = await request.json();
    } catch {
      return json({ error: 'invalid JSON body' }, 400);
    }
    const incoming = (Array.isArray(body) ? body : [body.url]).filter(Boolean);
    if (incoming.length === 0) return json({ error: 'no url provided' }, 400);
    const subs = await getSubs(env);
    let added = 0;
    let rejected = 0;
    for (const u of incoming) {
      const candidate = String(u).trim();
      if (!validUrl(candidate)) { rejected++; continue; }
      if (subs.includes(candidate)) continue;
      if (subs.length >= MAX_SUBS) { rejected++; continue; }
      subs.push(candidate);
      added++;
    }
    await putSubs(env, subs);
    return json({ subs, added, rejected });
  }

  if (request.method === 'DELETE') {
    if (!token) return json({ error: 'missing token' }, 401);
    let body;
    try {
      body = await request.json();
    } catch {
      return json({ error: 'invalid JSON body' }, 400);
    }
    const target = String(body.url || '').trim();
    const subs = (await getSubs(env)).filter((u) => u !== target);
    await putSubs(env, subs);
    return json({ subs, removed: target });
  }

  return json({ error: 'method not allowed' }, 405);
}

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    if (url.pathname === '/favicon.ico') {
      return new Response(null, { status: 204 });
    }

    if (url.pathname === '/api/subs') {
      return handleSubs(request, env);
    }
    if (url.pathname === '/api/health') {
      if (request.method !== 'POST') return json({ error: 'method not allowed' }, 405);
      const token = request.headers.get('x-gayroxy-token') || '';
      if (env.API_TOKEN && token !== env.API_TOKEN) return json({ error: 'unauthorized' }, 401);
      const body = await request.text();
      if (body.length > 256000) return json({ error: 'health report too large' }, 413);
      await env.ASSETS.put('health.json', body, { metadata: { updatedAt: new Date().toISOString() } });
      return json({ ok: true });
    }

    if (url.pathname === '/health.json') {
      const health = await env.ASSETS.get('health.json', { type: 'text' });
      return health ? new Response(health, { headers: { 'content-type': 'application/json; charset=utf-8', 'cache-control': 'no-store', 'access-control-allow-origin': '*' } }) : new Response('{}', { status: 404 });
    }

    const key = resolveKey(url.pathname);
    const value = isBinary(key)
      ? await env.ASSETS.get(key, { type: 'arrayBuffer' })
      : await env.ASSETS.get(key, { type: 'text' });

    if (value === null || value === undefined) {
      return new Response('Not Found', {
        status: 404,
        headers: { 'content-type': 'text/plain; charset=utf-8' },
      });
    }

    // sub/panel/index rotate every run (quick-tunnel URL changes) — short cache
    // so clients pick up the new tunnel URL fast. Geo databases are stable.
    const cacheControl = key.startsWith('geo/')
      ? 'public, max-age=86400, immutable'
      : 'public, max-age=60';

    return new Response(value, {
      headers: {
        'content-type': contentType(key),
        'cache-control': cacheControl,
        'access-control-allow-origin': '*',
      },
    });
  },
};

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

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    if (url.pathname === '/favicon.ico') {
      return new Response(null, { status: 204 });
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

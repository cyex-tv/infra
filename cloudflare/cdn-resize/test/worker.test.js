// The Worker's fetch handler with Cloudflare's `fetch` and `caches` stood in for.
import assert from 'node:assert/strict';
import { test } from 'node:test';

import worker from '../src/index.js';

const SHA = 'cd'.repeat(32);

function edge({ origin = () => new Response('pixels', { headers: { 'content-type': 'image/webp' } }) } = {}) {
  const seen = [];
  const store = new Map();
  globalThis.fetch = async (input, init) => {
    seen.push({ url: typeof input === 'string' ? input : input.url, init });
    return origin(input, init);
  };
  globalThis.caches = {
    default: {
      match: async (req) => store.get(req.url)?.clone(),
      put: async (req, res) => void store.set(req.url, res),
      delete: async (req) => store.delete(req.url),
    },
  };
  const waits = [];
  const ctx = { waitUntil: (p) => waits.push(p) };
  const call = async (path, init = {}) => {
    const res = await worker.fetch(new Request(`https://cdn.cyex.tv${path}`, init), {}, ctx);
    await Promise.all(waits.splice(0));
    return res;
  };
  return { seen, store, call };
}

test('a plain request is passed through as it came', async () => {
  const e = edge();
  const res = await e.call(`/emotes/${SHA}/2x.webp`);
  assert.equal(res.status, 200);
  assert.equal(e.seen.length, 1);
  assert.equal(e.seen[0].url, `https://cdn.cyex.tv/emotes/${SHA}/2x.webp`);
  assert.equal(e.seen[0].init, undefined);
});

test('a resize asks Cloudflare Images for our own file and caches it for good', async () => {
  const e = edge();
  const res = await e.call(`/emotes/${SHA}/4x.webp?w=48`);
  assert.equal(res.status, 200);
  assert.equal(res.headers.get('cache-control'), 'public, max-age=31536000, immutable');
  assert.equal(res.headers.get('vary'), null);
  assert.equal(await res.text(), 'pixels');
  assert.deepEqual(e.seen[0], {
    url: `https://cdn.cyex.tv/emotes/${SHA}/4x.webp`,
    init: { cf: { image: { fit: 'scale-down', format: 'webp', quality: 85, anim: true, metadata: 'none', width: 48 } } },
  });
  assert.deepEqual([...e.store.keys()], [`https://cdn.cyex.tv/emotes/${SHA}/4x.webp?w=48&format=webp`]);
  // The second time comes from the cache, after a HEAD of the original (an edge hit).
  const again = await e.call(`/emotes/${SHA}/4x.webp?w=48`);
  assert.equal(await again.text(), 'pixels');
  assert.equal(e.seen.length, 2);
  assert.deepEqual(e.seen[1], { url: `https://cdn.cyex.tv/emotes/${SHA}/4x.webp`, init: { method: 'HEAD' } });
});

test('a taken-down original takes its cached variants with it', async () => {
  let live = true;
  const e = edge({ origin: () => (live ? new Response('pixels', { headers: { 'content-type': 'image/webp' } }) : new Response(null, { status: 404 })) });
  assert.equal((await e.call(`/emotes/${SHA}/2x.webp?w=32`)).status, 200);
  assert.equal(e.store.size, 1);
  live = false;
  const res = await e.call(`/emotes/${SHA}/2x.webp?w=32`);
  assert.equal(res.status, 404);
  assert.equal(res.headers.get('cache-control'), 'public, max-age=60');
  assert.equal(e.store.size, 0);
});

test('format=auto varies by Accept', async () => {
  const e = edge({ origin: () => new Response('a', { headers: { 'content-type': 'image/avif' } }) });
  const res = await e.call(`/emotes/${SHA}/2x.webp?w=32&format=auto`, { headers: { accept: 'image/avif,image/webp' } });
  assert.equal(res.headers.get('vary'), 'Accept');
  assert.equal(res.headers.get('content-type'), 'image/avif');
  assert.equal(e.seen[0].init.cf.image.format, 'avif');
});

test('a missing file or a failed resize is never cached for long', async () => {
  const missing = edge({ origin: () => new Response('no', { status: 404 }) });
  const res = await missing.call(`/emotes/${SHA}/2x.webp?w=32`);
  assert.equal(res.status, 404);
  assert.equal(res.headers.get('cache-control'), 'public, max-age=60');
  assert.equal(missing.store.size, 0);
  const broken = edge({ origin: () => new Response('err', { status: 500 }) });
  const failed = await broken.call(`/emotes/${SHA}/2x.webp?w=32`);
  assert.equal(failed.status, 502);
  assert.equal(failed.headers.get('cache-control'), 'no-store');
  assert.equal(broken.store.size, 0);
});

test('a refused request never reaches the origin', async () => {
  const e = edge();
  for (const path of [`/originals/${SHA}?w=48`, `/emotes/${SHA}/2x.webp?w=49`, `/emotes/${SHA}/2x.webp?w=48&url=http://169.254.169.254/`]) {
    const res = await e.call(path);
    assert.equal(res.status, 400, path);
  }
  assert.equal(e.seen.length, 0);
});

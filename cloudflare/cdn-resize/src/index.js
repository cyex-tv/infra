// cdn.cyex.tv: on-the-fly resizing of emote, badge and paint pictures (platform ADR 0037).
//
// `GET /emotes/<sha256>/2x.webp?w=48&format=auto` answers the picture 48 px wide (never wider
// than the file itself), as WebP or AVIF, cached at the edge for a year under one key per file,
// width and format. Requests without `w` or `format` pass through untouched, so everything that
// works today keeps working; a request this Worker can't take is refused with a plain 400.
//
// Resizing is Cloudflare Images (transformations through `fetch` with `cf.image`); the original
// comes from the CDN origin (tv-cdn through the tunnel), never from a URL a client names.

import { IMMUTABLE, plan } from './plan.js';

/** Our CDN host. A variable (`CDN_HOST`) only so a staging zone can reuse the Worker. */
const DEFAULT_HOST = 'cdn.cyex.tv';

/** WebP and AVIF quality, as the worker's own files use (ADR 0012: WebP 90). */
const QUALITY = 85;

function refuse(status, message) {
  return new Response(`${status} ${message}\n`, {
    status,
    headers: {
      'content-type': 'text/plain; charset=utf-8',
      // A refusal never changes for the same URL, but keep it short in case the rules widen.
      'cache-control': 'public, max-age=300',
      'access-control-allow-origin': '*',
      'x-content-type-options': 'nosniff',
    },
  });
}

function gone() {
  return new Response('404 not found\n', {
    status: 404,
    headers: {
      'content-type': 'text/plain; charset=utf-8',
      'cache-control': 'public, max-age=60',
      'access-control-allow-origin': '*',
      'x-content-type-options': 'nosniff',
    },
  });
}

export default {
  /**
   * @param {Request} request
   * @param {{ CDN_HOST?: string }} env
   * @param {{ waitUntil(p: Promise<unknown>): void }} ctx
   */
  async fetch(request, env, ctx) {
    const host = env.CDN_HOST || DEFAULT_HOST;
    const step = plan(request.url, request.method, (name) => request.headers.get(name), host);
    if (step.action === 'pass') return fetch(request);
    if (step.action === 'refuse') return refuse(step.status, step.message);

    const cache = caches.default;
    const key = new Request(step.cacheKey, { method: 'GET' });
    const hit = await cache.match(key);
    if (hit) {
      // A takedown deletes the original and purges its URL, not the variants made from it (their
      // keys differ). So a variant is served only while its original still is: a HEAD that the
      // edge answers from its own cache for every live file.
      const original = await fetch(step.origin, { method: 'HEAD' });
      if (original.status === 404 || original.status === 410) {
        ctx.waitUntil(cache.delete(key));
        return gone();
      }
      return request.method === 'HEAD' ? new Response(null, hit) : hit;
    }

    const image = { fit: 'scale-down', format: step.format, quality: QUALITY, anim: true, metadata: 'none' };
    if (step.width > 0) image.width = step.width;
    const made = await fetch(step.origin, { cf: { image } });
    if (!made.ok) {
      // A missing file or a failed resize: say so, cache briefly at most, never for a year.
      if (made.status === 404) return gone();
      return new Response('502 resize failed\n', {
        status: 502,
        headers: {
          'content-type': 'text/plain; charset=utf-8',
          'cache-control': 'no-store',
          'access-control-allow-origin': '*',
          'x-content-type-options': 'nosniff',
        },
      });
    }
    const headers = new Headers({
      'content-type': made.headers.get('content-type') ?? `image/${step.format}`,
      'cache-control': IMMUTABLE,
      'access-control-allow-origin': '*',
      'x-content-type-options': 'nosniff',
    });
    // `format=auto` picks by `Accept`: browsers and other caches must keep the two apart. The
    // edge cache already does (the resolved format is in its key).
    if (step.varyAccept) headers.set('vary', 'Accept');
    const response = new Response(made.body, { status: 200, headers });
    ctx.waitUntil(cache.put(key, response.clone()));
    return request.method === 'HEAD' ? new Response(null, response) : response;
  },
};

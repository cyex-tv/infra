// `npm test` in cloudflare/cdn-resize (Node 20 or later, no packages).
import assert from 'node:assert/strict';
import { test } from 'node:test';

import { WIDTHS, plan } from '../src/plan.js';

const HOST = 'cdn.cyex.tv';
const SHA = 'ab'.repeat(32);
const headers = (h = {}) => (name) => h[name] ?? null;
const run = (path, { method = 'GET', h = {}, host = HOST } = {}) => plan(`https://${host}${path}`, method, headers(h), host);

test('no w or format: passed on untouched, as before the Worker', () => {
  for (const path of [`/emotes/${SHA}/2x.webp`, `/emotes/${SHA}/2x.webp?v=1`, '/originals/x', '/', '/emotes/']) {
    assert.deepEqual(run(path), { action: 'pass' }, path);
  }
  assert.deepEqual(run(`/emotes/${SHA}/2x.webp`, { method: 'POST' }), { action: 'pass' });
});

test('the resizer fetching the original goes straight to the origin', () => {
  assert.deepEqual(run(`/emotes/${SHA}/2x.webp?w=48`, { h: { via: '1.1 image-resizing' } }), { action: 'pass' });
});

test('a listed width of one of our picture files is resized, keyed by sha, width and format', () => {
  for (const folder of ['emotes', 'cosmetics/badges', 'cosmetics/paints']) {
    const got = run(`/${folder}/${SHA}/4x.webp?w=48`);
    assert.deepEqual(got, {
      action: 'resize',
      origin: `https://${HOST}/${folder}/${SHA}/4x.webp`,
      cacheKey: `https://${HOST}/${folder}/${SHA}/4x.webp?w=48&format=webp`,
      width: 48,
      format: 'webp',
      varyAccept: false,
    });
  }
  // The format defaults to the file's own; a format change alone keeps the size.
  assert.equal(run(`/emotes/${SHA}/1x_static.avif?w=32`).format, 'avif');
  const only = run(`/emotes/${SHA}/original.webp?format=avif`);
  assert.equal(only.width, 0);
  assert.equal(only.cacheKey, `https://${HOST}/emotes/${SHA}/original.webp?w=0&format=avif`);
  // Parameter order doesn't make another entry.
  assert.equal(run(`/emotes/${SHA}/2x.webp?format=webp&w=64`).cacheKey, run(`/emotes/${SHA}/2x.webp?w=64&format=webp`).cacheKey);
});

test('format=auto picks AVIF only when the browser takes it, and varies by Accept', () => {
  const avif = run(`/emotes/${SHA}/2x.webp?w=64&format=auto`, { h: { accept: 'image/avif,image/webp,*/*' } });
  assert.equal(avif.format, 'avif');
  assert.equal(avif.varyAccept, true);
  assert.match(avif.cacheKey, /format=avif$/);
  const webp = run(`/emotes/${SHA}/2x.webp?w=64&format=auto`, { h: { accept: 'image/webp,*/*' } });
  assert.equal(webp.format, 'webp');
  assert.equal(run(`/emotes/${SHA}/2x.webp?w=64&format=auto`).format, 'webp');
});

test('widths: only the listed ones, as plain numbers', () => {
  for (const w of WIDTHS) assert.equal(run(`/emotes/${SHA}/2x.webp?w=${w}`).action, 'resize', String(w));
  for (const w of ['0', '17', '1025', '2048', '99999', '-48', '48.0', '048', '4e1', ' 48', '48px', '', '0x30', '١٢٨']) {
    const got = run(`/emotes/${SHA}/2x.webp?w=${encodeURIComponent(w)}`);
    assert.equal(got.action, 'refuse', w);
    assert.equal(got.status, 400, w);
  }
});

test('formats: webp, avif or auto only', () => {
  for (const f of ['png', 'jpeg', 'gif', 'svg', 'json', 'AVIF', '']) {
    assert.equal(run(`/emotes/${SHA}/2x.webp?w=48&format=${f}`).action, 'refuse', f);
  }
});

test('only our picture files, never another host, folder or name (no SSRF)', () => {
  const refused = [
    '/originals/' + SHA + '?w=48',
    `/originals/cosmetics/${SHA}?w=48`,
    `/uploads/01ABC?w=48`,
    `/emotes/${SHA}?w=48`,
    `/emotes/${SHA}/?w=48`,
    `/emotes/${SHA.slice(2)}/2x.webp?w=48`,
    `/emotes/${SHA.toUpperCase()}/2x.webp?w=48`,
    `/emotes/${SHA}/2x.png?w=48`,
    `/emotes/${SHA}/../../originals/${SHA}?w=48`,
    `/emotes/${SHA}/%2e%2e/2x.webp?w=48`,
    `/emotes/${SHA}/a%2Fb.webp?w=48`,
    `/emotes/${SHA}/2x.webp/x?w=48`,
    `/cosmetics/other/${SHA}/2x.webp?w=48`,
    `//evil.example/emotes/${SHA}/2x.webp?w=48`,
    `/emotes/${SHA}/2x.webp?w=48&url=https://evil.example/x.png`,
    `/emotes/${SHA}/2x.webp?w=48&w=64`,
    `/emotes/${SHA}/2x.webp?w=48&cachebust=1`,
  ];
  for (const path of refused) {
    const got = run(path);
    assert.equal(got.action, 'refuse', path);
    assert.equal(got.status, 400, path);
  }
  // A request for another host than the configured one is refused, whatever the route sends.
  const other = plan(`https://evil.example/emotes/${SHA}/2x.webp?w=48`, 'GET', headers(), HOST);
  assert.deepEqual([other.action, other.status], ['refuse', 400]);
  // Every origin is our own host and the checked path.
  for (const w of [16, 512]) {
    const got = run(`/cosmetics/badges/${SHA}/512.webp?w=${w}`);
    assert.ok(got.origin.startsWith(`https://${HOST}/cosmetics/badges/${SHA}/`));
    assert.ok(!got.origin.includes('?'));
  }
});

test('only GET and HEAD resize', () => {
  assert.equal(run(`/emotes/${SHA}/2x.webp?w=48`, { method: 'HEAD' }).action, 'resize');
  for (const method of ['POST', 'PUT', 'DELETE', 'OPTIONS']) {
    assert.deepEqual(run(`/emotes/${SHA}/2x.webp?w=48`, { method }).status, 405, method);
  }
});

// What the cdn.cyex.tv Worker does with one request (platform ADR 0037), as a pure function so
// it can be tested without Cloudflare: pass it on untouched, refuse it, or resize a picture.
//
// Only our own picture files are resized, only at listed widths, only to WebP or AVIF, and the
// origin request is built from the checked path on our own host: a client can't name another
// host, another bucket folder or a file outside the picture folders (no SSRF), and can't make
// unbounded variants (no cache or bill explosion).

/** The widths a picture can be asked for (`?w=`), in px. Smaller originals are never scaled up. */
export const WIDTHS = Object.freeze([
  16, 18, 20, 24, 28, 32, 36, 40, 48, 56, 64, 72, 80, 96, 112, 128, 144, 160, 192, 224, 256, 320,
  384, 448, 512, 640, 768, 1024,
]);

/** `?format=`: a fixed format, or `auto` (AVIF when the browser says it takes it, else WebP). */
export const FORMATS = Object.freeze(['webp', 'avif', 'auto']);

/** The query parameters this Worker reads. Any other one is refused when resizing. */
const PARAMS = new Set(['w', 'format']);

/**
 * A picture file the CDN serves: an emote's or a badge's or paint's, under its 64-hex sha256
 * folder, by its plain file name (`2x.webp`, `128_static.avif`, `original.webp`).
 */
const PICTURE = /^\/(emotes|cosmetics\/badges|cosmetics\/paints)\/([0-9a-f]{64})\/([0-9A-Za-z_]{1,32})\.(webp|avif)$/;

/** A long, immutable cache: the path is content-addressed and a width never changes its pixels. */
export const IMMUTABLE = 'public, max-age=31536000, immutable';

/**
 * Decides what to do.
 * @param {string} rawUrl the request URL
 * @param {string} method the request method
 * @param {(name: string) => string | null} header a request header, by lower-case name
 * @param {string} host our CDN host (`cdn.cyex.tv`): the only origin ever fetched
 * @returns {{ action: 'pass' }
 *   | { action: 'refuse', status: number, message: string }
 *   | { action: 'resize', origin: string, cacheKey: string, width: number, format: 'webp' | 'avif', varyAccept: boolean }}
 */
export function plan(rawUrl, method, header, host) {
  // The resizer fetches the original through this zone; that request must go straight to the
  // origin, or it would loop through this Worker.
  if (/image-resizing/i.test(header('via') ?? '')) return { action: 'pass' };
  let url;
  try {
    url = new URL(rawUrl);
  } catch {
    return { action: 'refuse', status: 400, message: 'bad url' };
  }
  const keys = [...url.searchParams.keys()];
  // No resize asked for: exactly what the CDN did before this Worker (query strings included).
  if (!keys.includes('w') && !keys.includes('format')) return { action: 'pass' };
  if (method !== 'GET' && method !== 'HEAD') return { action: 'refuse', status: 405, message: 'method not allowed' };
  if (url.hostname !== host) return { action: 'refuse', status: 400, message: 'wrong host' };
  const unknown = keys.find((k) => !PARAMS.has(k));
  if (unknown !== undefined) return { action: 'refuse', status: 400, message: `unknown parameter: only w and format` };
  if (keys.filter((k) => k === 'w').length > 1 || keys.filter((k) => k === 'format').length > 1)
    return { action: 'refuse', status: 400, message: 'repeated parameter' };
  // `pathname` is already normalised by URL (no `..`); the pattern takes only plain names anyway.
  const picture = PICTURE.exec(url.pathname);
  if (!picture) return { action: 'refuse', status: 400, message: 'only picture files can be resized' };

  const rawW = url.searchParams.get('w');
  let width = 0;
  if (rawW !== null) {
    if (!/^[1-9][0-9]{0,3}$/.test(rawW)) return { action: 'refuse', status: 400, message: 'w is a whole number of px' };
    width = Number(rawW);
    if (!WIDTHS.includes(width)) return { action: 'refuse', status: 400, message: `w is one of ${WIDTHS.join(', ')}` };
  }
  const rawFormat = url.searchParams.get('format') ?? picture[4];
  if (!FORMATS.includes(rawFormat)) return { action: 'refuse', status: 400, message: 'format is webp, avif or auto' };
  const varyAccept = rawFormat === 'auto';
  const format = varyAccept ? (/\bimage\/avif\b/i.test(header('accept') ?? '') ? 'avif' : 'webp') : rawFormat;
  // Without a width, keep the file's own size (a format change only).
  const path = url.pathname;
  const origin = `https://${host}${path}`;
  // One cache entry per file, width and resolved format: the sha in the path makes it immutable.
  const cacheKey = `https://${host}${path}?w=${width}&format=${format}`;
  return { action: 'resize', origin, cacheKey, width, format, varyAccept };
}

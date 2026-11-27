# cdn.cyex.tv resize Worker

Resizes emote, badge and paint pictures on request: `https://cdn.cyex.tv/emotes/<sha256>/4x.webp?w=48&format=auto`.
The decision is platform ADR 0037; the owner's steps to enable it are in
[`docs/setup/owner-steps.md`](https://github.com/cyex-tv/platform/blob/main/docs/setup/owner-steps.md) in cyex-tv/platform.

- Without `w` or `format` a request passes through untouched: the fixed files (`1x.webp`, `128.webp`, …) work as before.
- `w`: one of 16, 18, 20, 24, 28, 32, 36, 40, 48, 56, 64, 72, 80, 96, 112, 128, 144, 160, 192, 224, 256, 320, 384, 448, 512, 640, 768, 1024. Never wider than the file.
- `format`: `webp`, `avif` or `auto` (AVIF when `Accept` has `image/avif`, else WebP; the answer then varies by `Accept`). Default: the file's own.
- Only `/emotes/<sha256>/<name>.(webp|avif)` and `/cosmetics/(badges|paints)/<sha256>/<name>.(webp|avif)`, only `GET` and `HEAD`, no other query parameters. Anything else with `w` or `format` is a 400; the origin is always `cdn.cyex.tv` plus the checked path, so a client can't point it elsewhere.
- Cached at the edge for a year (`immutable`), one entry per file, width and format: the sha in the path means the pixels never change.

Tests (Node 20 or later, no packages): `cd cloudflare/cdn-resize && npm test`.

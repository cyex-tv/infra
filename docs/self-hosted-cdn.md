# Moving the CDN to our own server

Today emote, badge and paint pictures live in Cloudflare R2 (bucket `cyex-tv-cdn`) and are served
at `https://cdn.cyex.tv` through R2's custom domain, a WAF rule and a cache rule (platform
`docs/setup/owner-steps.md`, Phase 3). This plan moves storage and serving onto our own host, with
no code changes in the platform: storage is configured by env only.

## What changes, what doesn't

| | Today | After |
|---|---|---|
| Storage | R2 bucket `cyex-tv-cdn` | `versitygw` (S3 gateway, Apache-2.0) on the host, storing each object as a plain file |
| Serving | R2 custom domain + WAF rule | Caddy serving the same folder read-only, only `/emotes/` and `/cosmetics/` |
| Public address | `https://cdn.cyex.tv` | the same, so stored URLs, the site's CSP and the extension keep working |
| Upload / transcode / takedown code | unchanged | unchanged (it only talks S3) |
| Cloudflare cache purge on takedown | used | not needed when cdn.cyex.tv isn't proxied (see Option A) |

`versitygw` is what the platform's dev setup already runs (`platform/dev/docker-compose.yaml`),
so production uses the same S3 server the tests and the mock already use.

## Decide first: proxied or not

- **Option A, DNS only (grey cloud).** `cdn.cyex.tv` points straight at the host; Caddy gets its
  own TLS certificate. No Cloudflare limits or rules at all. The cost: the host's IP is public,
  there is no edge cache or DDoS shield, and every byte goes out over the host's own uplink
  (R2 egress is free today; check the host's bandwidth and traffic cap).
- **Option B, through the existing tunnel (orange cloud).** Cloudflare still caches at the edge
  and hides the IP, but files come from our disk instead of R2. Cloudflare's CDN terms and
  cache limits still apply, so this only removes R2 and the WAF-rule dependence.

Option A is the one that removes Cloudflare's limits, which is the goal; the steps below assume
it, with the B differences noted.

## Steps

### 1. Disk and folders (host)
- A volume with room for growth: today's bucket size (R2 → `cyex-tv-cdn` → Metrics) plus at least
  3× headroom. Emote files are small but many; use ext4 or xfs, not a network share.
- `/srv/cyex-tv/cdn/data` (objects) and `/srv/cyex-tv/cdn/meta` (versitygw's metadata).

### 2. Storage service (compose)
Add to `compose/docker-compose.yaml`, on the `cyextv` network, port bound to 127.0.0.1 only:

```yaml
  tv-s3:
    <<: *small
    image: versity/versitygw:v1.10.0
    environment:
      VGW_BACKEND: posix
      VGW_BACKEND_ARG: /data
    env_file: ["${CYEXTV_ENV_DIR:-/srv/cyex-tv/infra/env}/s3.env"]
    volumes:
      - /srv/cyex-tv/cdn/data:/data
    ports: ["127.0.0.1:7070:7070"]
```

`env/s3.env` (gitignored; add `env/s3.env.example`) holds `ROOT_ACCESS_KEY` and
`ROOT_SECRET_KEY`, long random values, never the dev ones. Create the bucket once:
`aws --endpoint-url http://127.0.0.1:7070 s3 mb s3://cyex-tv-cdn`.

### 3. Serving (Caddy)
Caddy on the host (or as a compose service with ports 80/443), reading the bucket folder
read-only:

```caddyfile
cdn.cyex.tv {
	root * /srv/cyex-tv/cdn/data/cyex-tv-cdn
	@public path /emotes/* /cosmetics/*
	handle @public {
		header Cache-Control "public, max-age=31536000, immutable"
		header Access-Control-Allow-Origin "*"
		header X-Content-Type-Options "nosniff"
		file_server
	}
	handle {
		respond 404
	}
	encode zstd gzip
}
```

- Only `/emotes/` and `/cosmetics/` are served; `/originals/` and everything else answer 404
  (this replaces today's WAF rule, and can't be forgotten for a new folder: new folders are
  closed until added here).
- Keys never change (they're content hashes), so the year-long immutable header is right.
- `.webp`, `.avif`, `.png` and `.gif` get the right `Content-Type` from their extension.
- Option B: skip TLS in Caddy (`http://cdn.cyex.tv:8083`, bound to 127.0.0.1) and add a tunnel
  hostname `cdn.cyex.tv → http://127.0.0.1:8083` in `docs/tunnel.md`.

### 4. Copy the existing files
With rclone, from R2 to the new server (R2 needs an API token with read on the bucket):

```sh
rclone sync r2:cyex-tv-cdn s3local:cyex-tv-cdn --checksum --transfers 16
```

Copy everything, `originals/` included (they're needed for re-transcodes and takedown checks).
Run it once ahead of time, then again right after step 5 to catch uploads made in between.

### 5. Switch the API and worker
In `env/api.env` and `env/worker.env`:

```
CYEX_TV_S3_ENDPOINT=http://tv-s3:7070
CYEX_TV_S3_BUCKET=cyex-tv-cdn
CYEX_TV_S3_ACCESS_KEY_ID=<from s3.env>
CYEX_TV_S3_SECRET_ACCESS_KEY=<from s3.env>
CYEX_TV_S3_REGION=auto
CYEX_TV_CDN_URL=https://cdn.cyex.tv
```

Option A: leave `CYEX_TV_CLOUDFLARE_ZONE_ID` and `CYEX_TV_CLOUDFLARE_PURGE_TOKEN` empty; the worker
then deletes taken-down files and logs that there is no cache to purge. Option B: keep them.

`PUBLIC_CDN_URL` stays `https://cdn.cyex.tv`, so the website image needn't be rebuilt.
Restart `api` and `worker`, then run the second rclone sync.

### 6. DNS cutover
- In Cloudflare → R2 → `cyex-tv-cdn` → Custom Domains, disconnect `cdn.cyex.tv`.
- Option A: add an `A` (and `AAAA`) record `cdn` → the host's IP, **DNS only**. Open 80/443 on
  the host firewall for Caddy. Option B: add the tunnel hostname instead.
- Delete the WAF rule `cyex.tv: block originals` and the cdn cache rule once traffic is on the
  new server (keep them until then).

### 7. Check
- `curl -I https://cdn.cyex.tv/emotes/<hash>/2x.webp` → 200, `image/webp`, the immutable header.
- `curl -I https://cdn.cyex.tv/cosmetics/badges/<hash>/2x.webp` → 200.
- `curl -I https://cdn.cyex.tv/originals/<anything>` → 404.
- Upload an emote and a badge on cyex.tv: both show their pictures within a minute.
- Take down a test emote: its files return 404.
- Add `cdn.cyex.tv` to the uptime checks in `docs/monitoring.md`, and the data folder to the
  backups in `docs/restores.md` (originals are the part that can't be made again).

### 8. Rolling back
Point the env back at R2 (`CYEX_TV_S3_ENDPOINT=https://<account>.r2.cloudflarestorage.com` and the
R2 keys), reconnect the custom domain, restore the WAF and cache rules, and `rclone sync` back
anything uploaded meanwhile. Nothing in the database changes either way, because file URLs are
built from `CYEX_TV_CDN_URL` and the object key.

## Open questions for the owner
- Option A or B.
- Which host and disk (size and bandwidth cap).
- Keep R2 as an off-site backup copy of `originals/` (cheap, no egress), or back up elsewhere.

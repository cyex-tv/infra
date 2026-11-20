# The CDN on our own server

Emote, badge and paint pictures are stored by `tv-s3` (versitygw, an S3 gateway that keeps each
object as a plain file) and served at `https://cdn.cyex.tv` by `tv-cdn` (Caddy). The api and worker
only talk S3, so the platform needs no code change: the storage is set by env.

This is Option A: `cdn.cyex.tv` is a DNS-only record that points at our host, and Caddy gets its own
TLS certificate. No Cloudflare limits, no Cloudflare cache. The host's IP is public and every byte
leaves over its own uplink, so the limits below matter.

We start with an empty bucket. Nothing is copied over from R2.

| | |
|---|---|
| Storage | `tv-s3`, S3 on `http://tv-s3:7070` inside the `cyextv` network, and on `127.0.0.1:7070` on the host |
| Serving | `tv-cdn`, ports 80 and 443 (TCP) and 443 (UDP, HTTP/3) |
| Files | `/srv/cyex-tv/cdn/data/cyex-tv-cdn/...` (`CDN_DATA_DIR`) |
| Served | `GET` and `HEAD` on `/emotes/*` and `/cosmetics/*` only. Everything else is 404, `/originals/` always |
| Config | `cdn/Caddyfile`, every number from `env/cdn.env` |

## Before you start

- A host with Docker and the compose plugin, the infra repo at `/srv/cyex-tv/infra` and the platform
  at `/srv/cyex-tv/platform` (`docs/deploy.md`).
- Ports 80 and 443 (TCP and UDP) reachable from the internet and not used by anything else on the
  host. Port 80 is needed for the certificate.
- Disk: a local ext4 or xfs volume, not a network share, with room for the emotes, the originals
  (the part that can't be made again) and at least three times today's size as headroom.
- Bandwidth: check the host's monthly traffic cap. R2 egress was free; ours isn't.
- Nothing else uses `cdn.cyex.tv` while you do this (the R2 custom domain comes off in step 4).

## Steps

### 1. The data folder
```bash
sudo mkdir -p /srv/cyex-tv/cdn/data
```
To put it on another volume, set `CDN_DATA_DIR=/that/folder` in the shell or in `compose.env`
(`docs/deploy.md`) before every compose command below. Both services use the same variable.

### 2. The keys
```bash
cd /srv/cyex-tv/infra/env
sudo cp s3.env.example s3.env
sudo cp cdn.env.example cdn.env
sudo chown root:docker s3.env cdn.env && sudo chmod 640 s3.env cdn.env
openssl rand -hex 16    # the access key
openssl rand -hex 32    # the secret key
sudo nano s3.env        # paste them as ROOT_ACCESS_KEY and ROOT_SECRET_KEY
```
Real keys, never the dev ones. `cdn.env` can stay as it is: every line in it is a commented default.

### 3. Point the api and worker at it
In `api.env` and `worker.env` (the same keys in both, and the same pair as `s3.env`):
```
CYEX_TV_S3_ENDPOINT=http://tv-s3:7070
CYEX_TV_S3_BUCKET=cyex-tv-cdn
CYEX_TV_S3_ACCESS_KEY_ID=<ROOT_ACCESS_KEY>
CYEX_TV_S3_SECRET_ACCESS_KEY=<ROOT_SECRET_KEY>
CYEX_TV_S3_REGION=auto
CYEX_TV_CDN_URL=https://cdn.cyex.tv
CYEX_TV_CLOUDFLARE_ZONE_ID=
CYEX_TV_CLOUDFLARE_PURGE_TOKEN=
```
The two Cloudflare lines stay empty: with no cache in front, the worker just deletes a taken-down
file and logs that there is nothing to purge. `PUBLIC_CDN_URL` is unchanged, so the website image
isn't rebuilt. Then check the files:
```bash
sudo /srv/cyex-tv/infra/scripts/preflight.sh
```

### 4. Take R2 off the domain
In Cloudflare: R2, `cyex-tv-cdn`, Settings, Custom Domains: disconnect `cdn.cyex.tv`. Leave the R2
bucket itself alone until you are sure (see Rolling back). Pictures are unavailable from here until
step 6 is done and the first uploads exist: the bucket starts empty.

### 5. Start it
```bash
cd /srv/cyex-tv/infra
docker compose -f compose/docker-compose.yaml up -d --build tv-s3 tv-s3-init tv-cdn
docker compose -f compose/docker-compose.yaml logs tv-s3-init tv-cdn
```
`tv-s3-init` makes the bucket `cyex-tv-cdn` and exits (`bucket cyex-tv-cdn is ready`). It checks first,
so running it again does nothing. `tv-cdn` starts after it, and Caddy fetches the certificate on the
first request or at start (`certificate obtained successfully` in its log). The first build takes a
few minutes because Caddy is compiled with the rate-limit plugin.

Then restart the services that write: `docker compose -f compose/docker-compose.yaml up -d api worker`.

If `tv-s3-init` failed (for example `tv-s3` was still starting), run it again; it only makes what is missing:
```bash
docker compose -f compose/docker-compose.yaml run --rm tv-s3-init
```

### 6. DNS
In Cloudflare, on the `cyex.tv` zone: `A cdn` to the host's IPv4 address, and `AAAA cdn` to its IPv6
address if it has one. **Proxy status: DNS only (grey cloud).** The R2 custom domain must be gone
(step 4), or the name is still taken.

### 7. Check
Upload an emote on cyex.tv, then take its hash from the picture URL, or look in
`/srv/cyex-tv/cdn/data/cyex-tv-cdn/emotes/`.
```bash
H=<hash>
curl -sI https://cdn.cyex.tv/emotes/$H/2x.webp          # 200, content-type: image/webp,
                                                        # cache-control: public, max-age=31536000, immutable,
                                                        # access-control-allow-origin: *
curl -sI https://cdn.cyex.tv/cosmetics/badges/<hash>/2x.webp   # 200 (after you upload a badge)
curl -sI https://cdn.cyex.tv/originals/$H               # 404, never 200
curl -sI https://cdn.cyex.tv/emotes/                    # 404, no listing
curl -sI -X POST https://cdn.cyex.tv/emotes/$H/2x.webp  # 405
```
The rate limit, from a machine you can afford to lock out for a minute:
```bash
for i in $(seq 1 700); do curl -s -o /dev/null -w '%{http_code}\n' https://cdn.cyex.tv/emotes/none; done | sort | uniq -c
```
You should see 404 for the first 150 or so (the burst limit), then 429. A 429 carries `Retry-After`. Or run
`scripts/smoke.sh`, which checks the open and the closed paths. Also: take down a test emote and
its files answer 404.

## Tuning the limits

All in `/srv/cyex-tv/infra/env/cdn.env`. Remove the `#`, set the value, then
`docker compose -f compose/docker-compose.yaml up -d tv-cdn` (it restarts with the new numbers).
To go back to a default, put the `#` back. Don't leave a variable set but empty.

| Variable | Default | What it does |
|---|---|---|
| `CDN_HOST` | `cdn.cyex.tv` | The name Caddy serves and gets a certificate for |
| `CDN_BUCKET` | `cyex-tv-cdn` | The bucket folder that is served, and the bucket `tv-s3-init` makes. Keep it equal to `CYEX_TV_S3_BUCKET` |
| `CDN_RATE_EVENTS` | `600` | Requests one visitor may make in `CDN_RATE_WINDOW`. The 601st gets 429 |
| `CDN_RATE_WINDOW` | `1m` | The window for the line above. Units: `s`, `m`, `h` |
| `CDN_BURST_EVENTS` | `150` | Requests one visitor may make in `CDN_BURST_WINDOW`. Stops a fast flood the minute limit would let through |
| `CDN_BURST_WINDOW` | `10s` | The window for the line above |
| `CDN_RATE_IPV4_PREFIX` | `32` | Bits of an IPv4 address that identify a visitor. `32` is one address; `24` groups a whole /24 |
| `CDN_RATE_IPV6_PREFIX` | `64` | The same for IPv6. `64` is one home or one machine, so cycling through addresses in a /64 doesn't help |
| `CDN_READ_HEADER_TIMEOUT` | `5s` | Time a client gets to send its request headers |
| `CDN_READ_TIMEOUT` | `10s` | Time to read the request body |
| `CDN_WRITE_TIMEOUT` | `30s` | Time to send a whole response. Raise it only if big files to slow phones get cut off |
| `CDN_IDLE_TIMEOUT` | `30s` | How long a quiet keep-alive connection is kept |
| `CDN_MAX_HEADER_SIZE` | `16KB` | Largest request header block |
| `CDN_MAX_BODY` | `1` | Largest request body in bytes. The CDN takes no uploads. `0` would switch the limit off, so it isn't the default |
| `CDN_TRUSTED_PROXIES` | (unset) | Address ranges, separated by spaces, of a proxy in front of the host. Unset means only `127.0.0.1`, which is right for DNS only |

How to think about the numbers. A page of emotes can load around a hundred pictures at once, so the
burst limit must stay above that; 150 in 10 seconds does. Raise `CDN_RATE_EVENTS` if real visitors
get 429s (watch `docker compose logs tv-cdn | grep '"status":429'`); lower it, or the burst, if the
host struggles. Visitors behind one shared address (a school, a mobile carrier) share one count, so
don't go very low. 429 responses are never cached. Missing files answer 404 and may be cached for
one minute; real files for a year, because the key is a content hash.

If one address floods, nothing else is needed: the 429s are cheap, and the limit is per address. For
an attack from many addresses at once this setup has no shield; the answer is Option B (the proxied
tunnel hostname, `cdn.cyex.tv` through Cloudflare again).

## Clean up in Cloudflare

Once the checks pass and traffic is on the new host:
- R2, `cyex-tv-cdn`, Custom Domains: `cdn.cyex.tv` is disconnected (step 4).
- Security, WAF, Custom rules: delete `cyex.tv: block originals`.
- Caching, Cache Rules: delete the `cdn` cache rule.
- The R2 API token the api and worker used: revoke it. The `CYEX_TV_CLOUDFLARE_PURGE_TOKEN` token
  too, if nothing else uses it.
- The R2 bucket can stay as a cold copy or be emptied later. It is empty of anything new from now on.
- In `monitoring/check.env`, remove the R2 usage settings if you set them.

## Rolling back

Point the env back at R2 (`CYEX_TV_S3_ENDPOINT=https://<account id>.r2.cloudflarestorage.com`, the R2
keys, and the purge variables), restart `api` and `worker`, reconnect the R2 custom domain on
`cdn.cyex.tv` (and delete the `A`/`AAAA` records first), restore the WAF and cache rules, and stop
`tv-cdn`. Files uploaded to `tv-s3` in the meantime are not in R2: copy them over first with
`rclone copy /srv/cyex-tv/cdn/data/cyex-tv-cdn r2:cyex-tv-cdn`. Nothing in the database changes
either way, because file URLs are built from `CYEX_TV_CDN_URL` and the object key.

## Backups

The data folder is the only copy of the originals. Add `/srv/cyex-tv/cdn/data` to the nightly
backup next to the database dump (`docs/restores.md`), for example
`rclone sync /srv/cyex-tv/cdn/data <remote>:cyex-tv-cdn-backup --checksum`, to an off-site remote.
Restore by putting the files back in the same place and running `up -d tv-s3`; objects are plain
files, so a copy of the folder is a complete copy. Log each restore test in `docs/restores.md`.
The certificate volume (`cyextv-cdn-certs`) needs no backup: Caddy asks for a new certificate.

## Uptime check

`monitoring/check.sh` has a `cdn` check (`docs/monitoring.md`): every 5 minutes it asks
`https://cdn.cyex.tv/emotes/health-probe` and expects 404 or 200. Set `CYEXTV_CDN_URL` in
`check.env` to change the address. Add an outside check as well (any uptime service) on the same
URL, expecting 404, so you hear about it when the whole host is down.

## Notes

- `tv-s3` is on `127.0.0.1:7070` only: the S3 API is never public. `tv-cdn` mounts the data folder
  read-only and has no keys.
- Updating Caddy or the plugin: change the pinned versions in `cdn/Dockerfile` on purpose and run
  `up -d --build tv-cdn`.
- `docker compose ... up` now needs `s3.env` to exist. It is a required file; `cdn.env` is optional.
- If the data folder's file system has no extended attributes, versitygw can't keep its metadata
  there. Use ext4 or xfs (the default on Linux), not a network share.

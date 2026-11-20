# The CDN on our own server

Emote, badge and paint pictures are stored by `tv-s3` (versitygw, an S3 gateway that keeps each
object as a plain file) and served at `https://cdn.cyex.tv` by `tv-cdn` (Caddy). The api and worker
only talk S3, so the platform needs no code change: the storage is set by env.

`cdn.cyex.tv` goes through the existing Cloudflare tunnel, like `cyex.tv` and `api.cyex.tv`:
- No ports are open on the host and its IP stays hidden. `cloudflared` (a container on the `cyextv`
  network) reaches `tv-cdn` as `http://cyex-tv-tv-cdn-1:80`; on the host it is only on `127.0.0.1:8083`.
- Cloudflare does TLS, caches the files at its edge (so most requests never reach the host) and
  absorbs floods.
- Caddy still limits each visitor by their real address (Cloudflare's `CF-Connecting-IP`), and serves
  only `/emotes/` and `/cosmetics/`.
- Because Cloudflare caches, takedowns must purge its cache: the worker needs the purge token.

| | |
|---|---|
| Storage | `tv-s3`, S3 on `http://tv-s3:7070` inside the `cyextv` network, and on `127.0.0.1:7070` on the host |
| Serving | `tv-cdn` (`cyex-tv-tv-cdn-1:80` on the `cyextv` network, `127.0.0.1:8083` on the host), reached through the tunnel hostname `cdn.cyex.tv` |
| Files | `/srv/cyex-tv/cdn/data/cyex-tv-cdn/...` (`CDN_DATA_DIR`) |
| Served | `GET` and `HEAD` on `/emotes/*` and `/cosmetics/*` only. Everything else is 404, `/originals/` always |
| Config | `cdn/Caddyfile`, every number from `env/cdn.env` |

We start with an empty bucket. Nothing is copied over from R2.

## Steps

Steps 1 to 3 are done once `tv-s3` runs with its own keys and the api and worker write to it. If
that is already the case, start at step 4.

### 1. The data folder
```bash
sudo mkdir -p /srv/cyex-tv/cdn/data
```
To put it on another volume, set `CDN_DATA_DIR=/that/folder` in the shell or in `compose.env`
(`docs/deploy.md`) before every compose command below. Use ext4 or xfs, not a network share.

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
`cdn.env` can stay as it is: every line in it is a commented default.

### 3. Point the api and worker at it
In `api.env` and `worker.env` (the same keys in both, and the same pair as `s3.env`):
```
CYEX_TV_S3_ENDPOINT=http://tv-s3:7070
CYEX_TV_S3_BUCKET=cyex-tv-cdn
CYEX_TV_S3_ACCESS_KEY_ID=<ROOT_ACCESS_KEY>
CYEX_TV_S3_SECRET_ACCESS_KEY=<ROOT_SECRET_KEY>
CYEX_TV_S3_REGION=auto
CYEX_TV_CDN_URL=https://cdn.cyex.tv
```

### 4. The purge token (worker)
Cloudflare caches every picture for up to a year, so a taken-down emote must be purged from its
cache. In Cloudflare: My Profile, API Tokens, Create Token, Custom token, permission
**Zone, Cache Purge, Purge**, zone resource **cyex.tv** only. Then in `worker.env`:
```
CYEX_TV_CLOUDFLARE_ZONE_ID=<the cyex.tv zone id, on the zone's Overview page>
CYEX_TV_CLOUDFLARE_PURGE_TOKEN=<the token>
```
If you set these up for R2 before, keep them as they are. Then check the env files:
```bash
sudo /srv/cyex-tv/infra/scripts/preflight.sh
```

### 5. Start it
```bash
cd /srv/cyex-tv/infra
docker compose -f compose/docker-compose.yaml --profile cdn up -d --build tv-s3 tv-s3-init tv-cdn
docker compose -f compose/docker-compose.yaml --profile cdn exec tv-cdn caddy validate --config /etc/caddy/Caddyfile
docker compose -f compose/docker-compose.yaml --profile cdn up -d api worker
curl -sI http://127.0.0.1:8083/emotes/none    # 404 from Caddy: it's up
```
`tv-s3-init` makes the bucket if it's missing and exits. The first build of `tv-cdn` takes a few
minutes because Caddy is compiled with the rate-limit plugin. If `caddy validate` or the build
fails, keep its output: nothing is public yet, so nothing is broken.

### 6. Move cdn.cyex.tv to the tunnel
In Cloudflare, in this order:
1. **R2**, `cyex-tv-cdn`, Settings, Custom Domains: disconnect `cdn.cyex.tv`. If you made an `A` or
   `AAAA` record for `cdn` by hand, delete it in DNS, Records.
2. **Zero Trust**, Networks, Tunnels, the cyex tunnel, **Public Hostnames**, Add a public hostname:
   subdomain `cdn`, domain `cyex.tv`, Service URL **`http://cyex-tv-tv-cdn-1:80`** (the container, like the other
   cyex.tv routes; with a `cloudflared` installed on the host it would be `http://127.0.0.1:8083`). Save.
   Cloudflare makes the DNS record itself (a proxied `CNAME` to the tunnel). If the tunnel is set up
   by a config file instead, add the `cdn.cyex.tv` rule from `docs/tunnel.md` and restart cloudflared.
3. **Caching**, Cache Rules: keep (or add) the rule for `cdn.cyex.tv`: when hostname equals
   `cdn.cyex.tv`, eligible for cache, Edge TTL and Browser TTL "respect origin".
4. **Security**, WAF, Custom rules: delete `cyex.tv: block originals`. Caddy now decides what is
   served; the old rule only blocks `/cosmetics/` (badge and paint pictures) by mistake.

### 7. Check
Upload an emote and a badge on cyex.tv, then take their hashes from the picture URLs, or look in
`/srv/cyex-tv/cdn/data/cyex-tv-cdn/`.
```bash
H=<emote hash>
curl -sI https://cdn.cyex.tv/emotes/$H/2x.webp          # 200, content-type: image/webp,
                                                        # cache-control: public, max-age=31536000, immutable
curl -sI https://cdn.cyex.tv/cosmetics/badges/<hash>/2x.webp   # 200
curl -sI https://cdn.cyex.tv/originals/$H               # 404, never 200
curl -sI https://cdn.cyex.tv/emotes/                    # 404, no listing
curl -sI -X POST https://cdn.cyex.tv/emotes/$H/2x.webp  # 405
```
A second request for the same picture shows `cf-cache-status: HIT`: Cloudflare served it from its
cache. Also take down a test emote: within a minute its files answer 404 (the worker purged them).

The rate limit, from a machine you can afford to lock out for a minute (missing files aren't cached
for long, so these reach Caddy):
```bash
for i in $(seq 1 700); do curl -s -o /dev/null -w '%{http_code}\n' "https://cdn.cyex.tv/emotes/none-$i"; done | sort | uniq -c
```
You should see 404 for the first 150 or so (the burst limit), then 429.

## Tuning the limits

All in `/srv/cyex-tv/infra/env/cdn.env`. Remove the `#`, set the value, then
`docker compose -f compose/docker-compose.yaml --profile cdn up -d tv-cdn`.
To go back to a default, put the `#` back. Don't leave a variable set but empty.

| Variable | Default | What it does |
|---|---|---|
| `CDN_HOST` | `cdn.cyex.tv` | The name Caddy serves (it answers any name on its port too) |
| `CDN_BUCKET` | `cyex-tv-cdn` | The bucket folder that is served, and the bucket `tv-s3-init` makes. Keep it equal to `CYEX_TV_S3_BUCKET` |
| `CDN_RATE_EVENTS` | `600` | Requests one visitor may make in `CDN_RATE_WINDOW`. The 601st gets 429 |
| `CDN_RATE_WINDOW` | `1m` | The window for the line above. Units: `s`, `m`, `h` |
| `CDN_BURST_EVENTS` | `150` | Requests one visitor may make in `CDN_BURST_WINDOW`. Stops a fast flood the minute limit would let through |
| `CDN_BURST_WINDOW` | `10s` | The window for the line above |
| `CDN_RATE_IPV4_PREFIX` | `32` | Bits of an IPv4 address that identify a visitor. `32` is one address; `24` groups a whole /24 |
| `CDN_RATE_IPV6_PREFIX` | `64` | The same for IPv6. `64` is one home or one machine |
| `CDN_READ_HEADER_TIMEOUT` | `5s` | Time a client gets to send its request headers |
| `CDN_READ_TIMEOUT` | `10s` | Time to read the request body |
| `CDN_WRITE_TIMEOUT` | `30s` | Time to send a whole response |
| `CDN_IDLE_TIMEOUT` | `30s` | How long a quiet keep-alive connection is kept |
| `CDN_MAX_HEADER_SIZE` | `16KB` | Largest request header block |
| `CDN_MAX_BODY` | `1` | Largest request body in bytes. The CDN takes no uploads |
| `CDN_TRUSTED_PROXIES` | `private_ranges` | Who may name the visitor's address (`CF-Connecting-IP`): cloudflared on this host, which reaches Caddy from a private address through Docker. Leave it |

The limits only see requests that reach the host: what Cloudflare serves from its cache never
counts. A page of emotes can load around a hundred pictures at once, so the burst limit must stay
above that. Raise `CDN_RATE_EVENTS` if real visitors get 429s (watch
`docker compose logs tv-cdn | grep '"status":429'`); lower it, or the burst, if the host struggles.
429 responses are never cached. Missing files answer 404 and are cached for one minute; real files
for a year, because the key is a content hash.

## Rolling back

Point the env back at R2 (`CYEX_TV_S3_ENDPOINT=https://<account id>.r2.cloudflarestorage.com` and the
R2 keys), restart `api` and `worker`, remove the `cdn` public hostname from the tunnel, reconnect the
R2 custom domain on `cdn.cyex.tv`, restore the WAF rule (with `/cosmetics/` allowed) and stop
`tv-cdn`. Files uploaded to `tv-s3` in the meantime are not in R2: copy them first with
`rclone copy /srv/cyex-tv/cdn/data/cyex-tv-cdn r2:cyex-tv-cdn`. Nothing in the database changes
either way, because file URLs are built from `CYEX_TV_CDN_URL` and the object key.

## Backups

The data folder is the only copy of the originals. Add `/srv/cyex-tv/cdn/data` to the nightly
backup next to the database dump (`docs/restores.md`), for example
`rclone sync /srv/cyex-tv/cdn/data <remote>:cyex-tv-cdn-backup --checksum`, to an off-site remote.
Restore by putting the files back in the same place and running `up -d tv-s3`; objects are plain
files, so a copy of the folder is a complete copy. Log each restore test in `docs/restores.md`.

## Uptime check

`monitoring/check.sh` has a `cdn` check (`docs/monitoring.md`): every 5 minutes it asks
`https://cdn.cyex.tv/emotes/health-probe` and expects 404 or 200. Set `CYEXTV_CDN_URL` in
`check.env` to change the address.

## Notes

- `tv-s3` is on `127.0.0.1:7070` only and `tv-cdn` on `127.0.0.1:8083` only: nothing of the CDN is
  reachable except through the tunnel. `tv-cdn` mounts the data folder read-only and has no keys.
- Updating Caddy or the plugin: change the pinned versions in `cdn/Dockerfile` on purpose and run
  `up -d --build tv-cdn`.
- The CDN services are in the compose profile `cdn`: they start only with `--profile cdn` (or
  `COMPOSE_PROFILES=cdn` in the shell). Always include it from now on, or a plain `up` leaves the
  CDN as it is. With the profile, `s3.env` must exist; `cdn.env` is optional.
- If the data folder's file system has no extended attributes, versitygw can't keep its metadata
  there. Use ext4 or xfs (the default on Linux), not a network share.

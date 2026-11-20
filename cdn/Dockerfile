# Caddy with the per-IP rate limit plugin. Versions are pinned exactly; bump them on purpose.
#   caddy:        https://github.com/caddyserver/caddy/releases
#   caddy-ratelimit: a commit of https://github.com/mholt/caddy-ratelimit (it has only a v0.1.0 tag
#                 from before ipv4_prefix/ipv6_prefix existed, so the commit is pinned)
FROM caddy:2.11.9-builder AS build
RUN xcaddy build v2.11.9 \
    --with github.com/mholt/caddy-ratelimit@5625512f24f6f59d6f64fb3aafe5eecff0b286db

FROM caddy:2.11.9-alpine
COPY --from=build /usr/bin/caddy /usr/bin/caddy
COPY Caddyfile /etc/caddy/Caddyfile

# Cloudflare tunnel hostnames

cyex.tv uses the host's existing `cloudflared` tunnel with **new hostnames only**. Every
cyex.app hostname, route and rule stays as it is (platform AGENTS.md, "Separation from
cyex.app").

## Ingress rules to add

In the tunnel's config (or Zero Trust → Networks → Tunnels → the tunnel → Public Hostnames), add
these, **above** the final catch-all rule:

```yaml
ingress:
  # The event WebSocket (ADR 0005) goes to the events service.
  - hostname: api.cyex.tv
    path: ^/v1/events$
    service: http://127.0.0.1:8081
  # Everything else on the API, including GraphQL and its WebSocket.
  - hostname: api.cyex.tv
    service: http://127.0.0.1:8080
  # The website (the compose's `web` service).
  - hostname: cyex.tv
    service: http://127.0.0.1:8082
  # Emote, badge and paint pictures (the compose's `tv-cdn` service, profile `cdn`).
  - hostname: cdn.cyex.tv
    service: http://127.0.0.1:8083
  # ... cyex.app's existing rules, unchanged ...
  - service: http_status:404
```

`cdn.cyex.tv` is served by `tv-cdn` from our own storage (`docs/self-hosted-cdn.md`). Before that it was
R2's custom domain (platform `docs/setup/owner-steps.md`, Phase 3); disconnect that first, or the name
is taken.

## Settings that matter

- **WebSockets** are on by default on Cloudflare; keep them on for `api.cyex.tv`.
- The event socket sends a heartbeat every 20 s, under Cloudflare's 100 s idle timeout.
- The api and events services take the client IP from `CF-Connecting-IP`
  (`CYEX_TV_TRUST_CLOUDFLARE=true` in the compose). Their ports bind to 127.0.0.1, so nothing
  reaches them except through the tunnel.

## DNS

Creating a public hostname in the dashboard adds the `CNAME` to the tunnel. Only `cyex.tv`
and `api.cyex.tv`, plus `www.cyex.tv` redirecting to `cyex.tv`:
- DNS: a proxied `CNAME www` → `cyex.tv`.
- Rules → Redirect Rules → new rule, "cyex.tv: www": when hostname equals `www.cyex.tv`,
  dynamic redirect to `concat("https://cyex.tv", http.request.uri.path)`, status 301, keep the
  query string.

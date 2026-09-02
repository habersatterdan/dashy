# Troubleshooting Guide

## Quick health checks

```bash
docker compose ps                      # STATUS should show (healthy)
docker compose logs -f dashy           # Dashy config / widget errors
docker compose logs -f nginx           # TLS / proxy errors
curl -k https://localhost/health       # -> ok
```

## The wall is blank / not rotating

- Check the kiosk service: `systemctl --user status dashy-kiosk.service`
- Confirm the URL loads in a normal browser: `https://<host>/signage/`
- The rotation logic lives in `assets/signage.html`. Override timing via query
  string, e.g. `https://<host>/signage/?rotate=45&reload=600`.
- Watchdog reloads a stalled frame after 20 s and the whole page every 5 min.

## Certificate warnings

Self-signed certs warn on first load. Options:
- Accept the exception once on the display device, **or**
- Replace `nginx/certs/signage.{crt,key}` with a trusted/internal-CA cert and
  `docker compose restart nginx`, **or**
- Put a corporate reverse proxy / load balancer in front (see below).

## A widget shows no data

- **Zabbix**: verify `hostname` and `apiToken` in `conf.yml` / `executive.yml`;
  the token needs API read rights. Test:
  `curl -k -H "Authorization: Bearer <token>" https://zabbix.example.local/api_jsonrpc.php`
- **RSS**: some feeds block server-side fetches; Dashy proxies them — check
  `docker compose logs dashy` for fetch errors.
- **Grafana iframe**: enable anonymous/kiosk access and set
  `allow_embedding = true` + `X-Frame-Options` on Grafana; use `&kiosk&theme=dark`.
- **Status dots red**: `statusCheck` couldn't reach the URL from the Pi — check
  DNS/routing/firewall from the Pi to that host.

## Containers keep restarting

```bash
docker compose logs --tail=100 <service>
docker inspect --format '{{json .State.Health}}' dashy | jq
```
`restart: unless-stopped` policy will keep retrying; fix the root cause in logs.

## Screen blanks / powers off

Handled by `kiosk.sh` (`xset -dpms`, `xset s off`). On Wayland, disable screen
blanking in the desktop power settings, or set `wlr-randr`/`labwc` accordingly.

## Reverse proxy option (production)

Terminate TLS on an existing corporate proxy (F5/NGINX/Traefik) and forward to
the Pi's port 443 (or expose Dashy on 8080 internally and proxy that). Keep the
`/admin` basic-auth gate and `/health` route intact.

## Reset / redeploy

```bash
docker compose down
docker compose up -d
```

## Low disk space

```bash
docker image prune -f
docker system df
ls -lt backups/ | tail   # old backups auto-rotate (KEEP=14)
```

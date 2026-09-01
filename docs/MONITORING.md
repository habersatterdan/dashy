# Monitoring Integration Examples

Copy these snippets into `dashy/conf.yml` or `dashy/pages/*.yml`. Replace every
`REPLACE_WITH_*` and `*.example.local` value. Dashy widget reference:
https://dashy.to/docs/widgets

## Zabbix — problem feed

```yaml
- type: zabbix-problems
  updateInterval: 60
  options:
    hostname: https://zabbix.example.local
    apiToken: REPLACE_WITH_ZABBIX_API_TOKEN   # Zabbix -> Users -> API tokens
    count: 12
```

Create the token in Zabbix under *Users → API tokens*; a read-only role is
enough. Test it:

```bash
curl -k -X POST https://zabbix.example.local/api_jsonrpc.php \
  -H "Content-Type: application/json-rpc" \
  -H "Authorization: Bearer REPLACE_WITH_ZABBIX_API_TOKEN" \
  -d '{"jsonrpc":"2.0","method":"problem.get","params":{"limit":5},"id":1}'
```

## Grafana — embedded panel (iframe)

```yaml
- type: iframe
  options:
    url: https://grafana.example.local/d/UID/dashboard?orgId=1&kiosk&theme=dark
    frameHeight: 460
```

Grafana `grafana.ini` must allow embedding:

```ini
[security]
allow_embedding = true
[auth.anonymous]
enabled = true
org_role = Viewer
```

Use `/d-solo/UID?panelId=N` for a single panel, `&kiosk` to hide chrome.

## PRTG — sensor status via REST

PRTG exposes JSON at `/api/table.json`. Use a generic API widget:

```yaml
- type: api-response
  updateInterval: 60
  options:
    url: https://prtg.example.local/api/table.json?content=sensors&columns=sensor,status,message&count=10&username=REPLACE_USER&passhash=REPLACE_PASSHASH
    method: GET
```

Get the passhash from *Setup → Account Settings → My Account → Show Passhash*.

## CheckMK — service problems via REST API

```yaml
- type: api-response
  updateInterval: 60
  options:
    url: https://checkmk.example.local/mysite/check_mk/api/1.0/domain-types/service/collections/all?query=%7B%22op%22%3A%22%3D%22%2C%22left%22%3A%22state%22%2C%22right%22%3A%222%22%7D
    method: GET
    headers:
      Authorization: "Bearer automation REPLACE_WITH_AUTOMATION_SECRET"
      Accept: application/json
```

Create the automation user in CheckMK (*Setup → Users*) and use its secret.

## Microsoft 365 — Service Health

Simplest (no API): link tiles to the admin/status portals (already in
`conf.yml`). For live data, query Microsoft Graph
`/admin/serviceAnnouncement/healthOverviews` with an app registration
(`ServiceHealth.Read.All`) and surface it through a small proxy or the
`api-response` widget:

```yaml
- type: api-response
  updateInterval: 300
  options:
    url: https://graph.microsoft.com/v1.0/admin/serviceAnnouncement/healthOverviews
    method: GET
    headers:
      Authorization: "Bearer REPLACE_WITH_GRAPH_ACCESS_TOKEN"
```

Token via client-credentials flow using `M365_TENANT_ID`/`CLIENT_ID`/`SECRET`
from `.env`. Refresh it with a cron/sidecar since Graph tokens are short-lived.

## Health-check tiles (any HTTP endpoint)

```yaml
- type: health-check
  updateInterval: 60
  options:
    urls:
      - label: Core Switch
        url: https://core-sw-01.example.local
      - label: Firewall
        url: https://firewall.example.local
```

## Weather + Clock

```yaml
- type: clock
  options: { timeZone: Europe/Berlin, format: en-GB }
- type: weather
  updateInterval: 600
  options:
    apiKey: REPLACE_WITH_OPENWEATHERMAP_KEY
    city: Vienna
    units: metric
```

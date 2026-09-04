# Schritt-für-Schritt: Einrichtung auf dem Pi

Diese Anleitung führt vom aktuellen Repo-Stand bis zur laufenden Wand inkl.
CVE-Webhooks. Jeder Schritt hat eine Prüfung — erst weitergehen, wenn sie passt.

---

## Schritt 1 — Stand holen

```bash
cd ~/dashy
git fetch origin claude/noc-signage-raspberry-pi-ea7gg2
git reset --hard origin/claude/noc-signage-raspberry-pi-ea7gg2
```

`--hard` ist hier sicher: `.env`, `config/*.env`, `nginx/certs/*` und `state/`
sind gitignored und bleiben unberührt.

**Prüfung**
```bash
git log --oneline -1
ls config/ services/cve-watcher/ scripts/render-config.py
```

---

## Schritt 2 — Zentrale Konfiguration anlegen

```bash
cp config/endpoints.env.example config/endpoints.env
cp config/secrets.env.example   config/secrets.env
chmod 600 config/secrets.env
grep -q DASHY_PROFILE .env || echo "DASHY_PROFILE=enterprise" >> .env
```

Ab jetzt trägst du URLs und Zugangsdaten **nur noch hier** ein.

---

## Schritt 3 — Eure Werte eintragen

```bash
nano config/endpoints.env     # Zabbix, vCenter, Firewall, Backup ...
nano config/watchlist.txt     # Produkte, die ihr einsetzt (fuer den CVE-Watcher)
```

Nicht genutzte Zeilen einfach leer lassen. Die Watchlist entscheidet, welche
CVEs euch überhaupt betreffen — sie ist der wichtigste Filter.

---

## Schritt 4 — Konfiguration rendern

```bash
./scripts/render-config.py
```

Der Renderer füllt die Vorlagen (`*.tmpl`) und listet am Ende auf, was noch
keinen Wert hat. Fehlende Werte bleiben als `${VAR}` sichtbar stehen.

**Prüfung** — es darf nichts Wichtiges mehr offen sein:
```bash
grep -n '\${' profiles/enterprise/conf.yml || echo "alle Platzhalter gefuellt"
```

---

## Schritt 5 — Stack starten

```bash
sudo docker compose up -d      # 'up -d', nicht 'restart': neue Services
docker compose ps
```

Erwartet: `dashy`, `nginx`, `watchtower`, `shotter`, `cve-watcher`.

**Wenn nginx nicht startet:**
```bash
docker compose logs nginx | tail -20
```
Die Fehlermeldung nennt Datei und Zeile.

---

## Schritt 6 — Feeds prüfen

```bash
./scripts/check-feeds.sh https://localhost
```

Zeigt je Quelle HTTP-Status, Content-Type und ob echtes XML/JSON ankommt.
`KEIN FEED` bei `heise-alerts` bedeutet: die URL in
`nginx/conf.d/dashy.conf` stimmt nicht — dann die richtige eintragen und
`docker compose restart nginx`.

---

## Schritt 7 — Wand ansehen

```
https://<pi>/wall/        Alert-Wand (KPI + Meldungsstrom)
https://<pi>/signage/     Rotation über alle Seiten
https://<pi>/             Dashy-Übersicht
```

---

## Schritt 8 — CVE-Watcher beobachten (noch ohne Senden)

Der Watcher startet mit `CVE_DRY_RUN=true` und schreibt nur ins Log.

```bash
docker compose logs -f cve-watcher
```

Erwartete Ausgabe:
```
Watchlist: 26 Begriffe | MIN_CVSS=7.0 | DRY_RUN=True | Intervall=1800s
KEV: 1247 bekannte ausgenutzte CVEs
  Cisco PSIRT: 20 Eintraege
  [DRY_RUN] wuerde senden: CVE-2026-20212 P1 cvss=9.8
```

**Erst weitergehen, wenn hier die richtigen Meldungen auftauchen.** Zu viele
Treffer → Watchlist enger fassen. Zu wenige → Begriffe ergänzen.

> Ohne `NVD_API_KEY` wartet der Watcher 7 s je CVE (Rate-Limit). Ein Key ist
> kostenlos unter nvd.nist.gov und macht den ersten Lauf deutlich schneller.

---

## Schritt 9 — Webhook testen (mit dem Test-Empfänger)

**Terminal A** — Empfänger starten:
```bash
./scripts/test-webhook-receiver.py 9000
```

**Terminal B** — Ziel eintragen und scharf schalten:
```bash
nano config/secrets.env      # CVE_WEBHOOK_URL=http://172.17.0.1:9000/hook
sed -i 's/^CVE_DRY_RUN=.*/CVE_DRY_RUN=false/' .env
sudo docker compose up -d cve-watcher
```

`172.17.0.1` ist der Pi aus Sicht der Container (Docker-Bridge). In Terminal A
erscheint jetzt das JSON jeder Meldung.

**Danach wieder aufräumen:** Empfänger stoppen (Strg+C) und das echte Ziel in
`CVE_WEBHOOK_URL` eintragen.

---

## Schritt 10 — Echtes Ziel anbinden

`CVE_WEBHOOK_URL` in `config/secrets.env` auf euren Endpoint setzen, optional
`CVE_WEBHOOK_AUTH_HEADER` (Format `Name: Wert`), dann:

```bash
sudo docker compose up -d cve-watcher
```

Siehe **Webhook-Empfänger** in der README für die Optionen.

---

## Häufige Stolpersteine

| Symptom | Ursache | Lösung |
|---|---|---|
| RSS-Kacheln „Unable to fetch data" | Container kennt Firmen-CA nicht | `nginx/certs/chain.crt` muss existieren |
| Seitenwechsel endet im 404 | Seite nicht in `pages:` registriert | `conf.yml` + `assets/signage.html` abgleichen |
| `no such service: cve-watcher` | alter Stand | Schritt 1 wiederholen |
| Watcher meldet nichts | Watchlist trifft nicht | Begriffe in `config/watchlist.txt` prüfen |
| Nach Update sind URLs weg | — | passiert nicht mehr: `./scripts/render-config.py` genügt |

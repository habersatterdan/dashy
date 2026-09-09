# NOC / Datacenter Digital Signage (Dashy on Raspberry Pi 5)

Production-ready, full-screen **Digital Signage** for a NOC / datacenter wall,
built on [Dashy](https://dashy.to). Runs on a **Raspberry Pi 5 (8 GB, Raspberry
Pi OS 64-bit)** with Docker + Docker Compose, behind an HTTPS Nginx reverse
proxy, auto-updated by Watchtower, and displayed in Chromium **kiosk mode** on
TVs, **Yealink MeetingBoard** and **Teams Rooms** browsers.

Die Wand rotiert selbstständig durch die konfigurierten Seiten, lädt regelmäßig
neu, erholt sich von Hängern und beugt Einbrennen vor — ohne jede Bedienung.

```
Raspberry Pi 5
├─ Docker ─── Dashy · Nginx (HTTPS) · Watchtower · Sonde · CVE-Watcher
├─ Seiten ─── Betriebslage · Anbieterstatus · Sicherheit · eigene Dashboards
└─ Rotation ─ Chromium Kiosk, Standzeit je Seite konfigurierbar
```

---

## Wo trage ich was ein?

**Die wichtigste Tabelle dieses Dokuments.** Alle Dateien unter `config/` sind
gitignored und überleben jedes Update — im Quelltext ändert man nichts.

| Ich will … | Datei | Danach |
|---|---|---|
| **Seiten der Wand festlegen** (Reihenfolge, Standzeit, eigene Dashboards) | `config/pages.txt` | `docker compose restart nginx` |
| **Anbieter auf `/stoerungen/`** festlegen | `config/sources.txt` | `docker compose restart nginx` |
| **Eigene Systeme überwachen** (erreichbar? wie schnell? Zertifikat?) | `config/probes.txt` | `docker compose restart probe` |
| **Adressen hinterlegen** (Zabbix, Grafana, vCenter, Firewall …) | `config/endpoints.env` | `./scripts/update.sh` |
| **Zugangsdaten hinterlegen** (API-Token, Webhook-URLs) | `config/secrets.env` | `./scripts/update.sh` |
| **Eine Weboberfläche einbetten** (Grafana, PRTG, CheckMK …) | `config/endpoints.env` → `EMBED1_SLUG` + `EMBED1_URL` | `./scripts/update.sh` |
| **Produkte für CVE-Meldungen wählen** | `config/watchlist.txt` | `docker compose restart cve-watcher` |
| **Zeitzone, Intervalle, DNS-Krücken** | `.env` | `./scripts/update.sh` |

> **Nach einem Update:** Neue Schalter landen in `.env.example`, nicht
> automatisch in deiner `.env` — und ein **fehlender** Schlüssel wirkt wie ein
> absichtlich gesetzter Vorgabewert. `./scripts/update.sh` nennt am Ende, was
> fehlt; übernehmen mit `./scripts/update.sh --env-ergaenzen` (bestehende Werte
> bleiben unberührt, Sicherung in `.env.bak`).

Beim ersten Mal alle Vorlagen kopieren:

```bash
cd ~/dashy
for f in endpoints.env secrets.env probes.txt pages.txt; do
  [ -f config/$f ] || cp config/$f.example config/$f
done
chmod 600 config/secrets.env
./scripts/update.sh
```

Prüfen, ob etwas fehlt: `./scripts/render-config.py` listet jeden Platzhalter
ohne Wert und sagt, in welche Datei er gehört.

---

## Ein Dashboard sauber einbinden — in drei Schritten

Gilt für **jedes** Backend: Zabbix, Grafana, PRTG, CheckMK, vCenter, ein Wiki.

> **Warum es ohne Proxy nicht geht:** Fast alle diese Anwendungen senden
> `X-Frame-Options: SAMEORIGIN` oder eine CSP mit `frame-ancestors`. Ein
> `<iframe>` darauf bleibt von der Wand aus **leer — ohne Fehlermeldung**. Über
> den Proxy läuft die Anwendung unter *eurer* Adresse (also same-origin), und
> die Sperre wird zusätzlich entfernt. Das ist der ganze Trick.

**Schritt 1 — Adresse hinterlegen** (`config/endpoints.env`):

```bash
# Zabbix ist vorkonfiguriert, dafür genügt:
ZABBIX_URL=http://zabbix.firma.local/zabbix

# Alles andere über die vier Einbett-Plätze:
EMBED1_SLUG=grafana
EMBED1_URL=https://grafana.firma.local
```

`SLUG` ist der Pfad, unter dem die Anwendung bei euch erscheint. **Immer den
vollen Namen (FQDN)** eintragen — Kurznamen lösen im Container nicht auf. Nur
die **Basisadresse**, keine kopierte URL aus der Adresszeile.

**Schritt 2 — anwenden und prüfen:**

```bash
./scripts/update.sh
./scripts/check-zabbix.sh          # prüft DNS, Port, TLS, Token, Proxy einzeln
```

Im Browser des Pi öffnen — hier wird sichtbar, ob es klappt:
`https://<pi>/grafana/` bzw. `https://<pi>/zabbix/`

**Schritt 3 — auf die Wand** (`config/pages.txt`):

```
# Name | Adresse | Sekunden
Betriebslage | /lage/                                                            | 60
Grafana      | /grafana/d/abc123/uebersicht?kiosk                                 | 60
Zabbix Netz  | /zabbix/zabbix.php?action=dashboard.view&dashboardid=420&kiosk=1  | 60
```

Dann `docker compose restart nginx`. Fertig — kein Quelltext angefasst.

### Die Vollbild-Parameter je Backend

Ohne diese steht das Menü der Anwendung mit auf der Wand:

| Backend | Parameter | Freigabe ohne Anmeldung |
|---|---|---|
| Zabbix | `&kiosk=1` | Dashboard → *Sharing → Public* (Benutzer `guest`) |
| Grafana | `?kiosk` (bzw. `&kiosk`) | Dashboard → *Share → Snapshot*, oder anonymen Zugriff aktivieren |
| CheckMK | Ansicht als „Dashboard" freigeben | Automation-User |
| PRTG | „Public Map" anlegen | Map-URL ohne Login |

Ohne Freigabe erscheint auf der Wand der Login der Anwendung — dann ist nicht
der Proxy schuld.

### Wenn es klemmt

| Symptom | Ursache | Behebung |
|---|---|---|
| `/…/` → **500 / 502** | Container löst den Namen nicht auf | FQDN eintragen; hilft das nicht: `EXTRA_HOST_1=name.firma.local:10.0.0.42` in `.env` |
| `/…/` → **404** | Datei nicht gerendert oder nginx nicht neu gestartet | `./scripts/render-config.py && ./scripts/update.sh` |
| Seite **leer, keine Fehlermeldung** | direkt auf `https://server…` eingebettet statt über den Proxy | immer den Proxy-Pfad verwenden |
| **Login** statt Dashboard | keine Freigabe in der Anwendung | siehe Tabelle oben |
| Schrift **zu klein** aus 5 m | Anwendung für Schreibtisch gebaut | über `/site/?w=1280&url=…` hochskalieren |
| **Dashy-404** (lila, „Page Not Found") | Adresse ohne Schrägstrich am Ende aufgerufen | `/signage/` statt `/signage` — die Umleitung fängt das inzwischen ab |
| Dashboard **taucht nicht auf** | Zeile fehlt in `config/pages.txt`, oder die Datei existiert nicht | `./scripts/check-wall.sh` |

### „Als Gast anmelden" automatisch klicken

Zabbix zeigt seine Dashboards erst nach einem Klick auf *Als Gast anmelden* —
dabei setzt es ein Sitzungs-Cookie. Auf einer Wand, die niemand bedient, ist
das ein Problem: `check-wall.sh` meldet dann bei jedem Dashboard „Zabbix
verlangt Anmeldung".

Dafür gibt es in `config/pages.txt` die `@login`-Zeile:

```
@login | /zabbix/index.php?form=default&enter=Sign+in+as+guest
```

Sie wird **einmal beim Start der Wand** unsichtbar aufgerufen, bevor die
Rotation beginnt. Weil alles über den Proxy same-origin läuft, gilt das Cookie
danach für alle Dashboard-Seiten. `@login`-Zeilen sind keine Wandseiten und
tauchen in der Rotation nicht auf; mehrere sind erlaubt (ein anderes Backend
mit eigener Anmeldung).

Das ersetzt keine echte Freigabe: Ist `guest` in Zabbix deaktiviert, hilft auch
der simulierte Klick nicht — dann bleibt nur *Dashboard → Sharing → Public*
oder ein Nur-Lese-Benutzer.

### Weitere RSS-Feeds ergänzen

Fest eingebaut sind `m365`, `azure`, `cisco`, `bsi`, `cisa`, `heise-alerts`,
`heise-security`, `kev`. Sechs weitere Plätze in `config/endpoints.env`:

```
FEED1_SLUG=fortinet
FEED1_URL=https://.../rss.xml
```

Danach steht der Feed unter `/feeds/fortinet` bereit. Welche Anbieter als
Karte auf `/stoerungen/` erscheinen, steht in `config/sources.txt`:

```
Microsoft 365 | m365
Fortinet      | fortinet
```

> **Vor dem Eintragen prüfen:**
> ```bash
> ./scripts/check-feeds.sh                # was die Wand sieht + direkte Quelle
> ./scripts/check-feeds.sh --kandidaten   # bekannte Alternativadressen testen
> ```
> Das Skript prüft **zweistufig**: einmal über den Proxy (was die Wand sieht)
> und einmal direkt zur Quelle. Erst dadurch ist unterscheidbar, ob nginx
> falsch konfiguriert ist oder der Anbieter die Adresse geändert hat.
>
> Das passiert regelmäßig: Microsoft hat `status.office365.com/api/feed/rss`
> zurückgezogen und `azureedge.net` abgeschaltet. **Deshalb stehen die
> Statusfeeds nicht mehr fest im Code**, sondern in `config/endpoints.env` —
> eine tote Adresse ist damit eine Zeile Arbeit, kein Update.

## Quick start

```bash
git clone <this-repo> ~/dashy && cd ~/dashy
sudo ./scripts/install.sh          # Docker, Zertifikat, Stack, Kiosk, Backup-Cron

# Die vier Dateien, in denen alles steht (siehe Tabelle oben):
$EDITOR config/endpoints.env       # Adressen eurer Systeme
$EDITOR config/secrets.env         # API-Token  (chmod 600)
$EDITOR config/probes.txt          # was gemessen wird
$EDITOR config/pages.txt           # was die Wand zeigt

./scripts/update.sh                # rendern + Container neu erzeugen
./scripts/check-zabbix.sh          # prüft die Anbindung Schicht für Schicht
```

Die Wand läuft unter **`https://<pi>/signage/`** — mit **Schrägstrich am Ende**.
Der Kiosk-Dienst öffnet sie beim Hochfahren von selbst. Einzelne Seiten direkt:
`/lage/`, `/stoerungen/`, `/wall/`.

Prüfen, ob wirklich jede Seite lädt — auch jedes Zabbix-Dashboard:

```bash
./scripts/check-wall.sh
```

Das ist der schnellste Weg zur Antwort „warum sehe ich mein Dashboard nicht":
eine kaputte Seite huscht in der Rotation nach 30 Sekunden vorbei und ist
wieder weg. Das Skript ruft jede Zeile aus `config/pages.txt` einzeln auf und
erkennt auch, ob Zabbix statt des Dashboards den Login liefert oder `&kiosk=1`
fehlt.

**Für ein Update immer `./scripts/update.sh`** — ein bloßes `git pull` reicht
nicht, siehe *Nach einem Update*.

## Profiles

The dashboard's content lives entirely under `profiles/<name>/` (a `conf.yml`
plus a `pages/` folder) — the rest of the stack (Docker, Nginx, kiosk,
backup) is content-agnostic and works with any profile. Pick one via
`DASHY_PROFILE` in `.env` (default: `enterprise`).

- **`enterprise`** — the original NOC/datacenter wall: Zabbix, M365, Cisco
  Catalyst Center/ISE, VMware/Hyper-V, MSRC/BSI/CISA advisories. Built for a
  corporate NOC screen or a Teams Room / Yealink MeetingBoard.
- **`homelab`** — a self-hosted starter: Proxmox, Grafana, Prometheus,
  Uptime Kuma, Pi-hole, Nextcloud, Vaultwarden, Gitea, Immich, Paperless-ngx,
  Home Assistant, plus a News page of real public RSS feeds (Heise, Golem,
  r/homelab, r/selfhosted, GitHub/Cloudflare status). Every service URL is a
  `DEINE-*-URL` placeholder — swap in your own hosts before going live.

Add your own environment by copying an existing `profiles/<name>/` folder,
editing `conf.yml`/`pages/*.yml`, and setting `DASHY_PROFILE=<name>`.

## Documentation

- [docs/SETUP-PI.md](docs/SETUP-PI.md) — **Schritt-für-Schritt auf dem Pi** (Konfiguration, Start, Webhook-Test)
- [docs/INSTALL.md](docs/INSTALL.md) — installation guide
- [docs/UPDATE.md](docs/UPDATE.md) — update guide (Watchtower + manual)
- [docs/BACKUP.md](docs/BACKUP.md) — backup & restore
- [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md) — troubleshooting
- [docs/MONITORING.md](docs/MONITORING.md) — Zabbix / PRTG / CheckMK / Grafana examples

## Running without the bundled Nginx

If you front this with your own reverse proxy (Traefik, Caddy, nginx-proxy-manager, ...)
instead of the bundled Nginx container, you must still serve `profiles/<profile>/pages/*.yml`
as static files at `/pages/*.yml` (or point your proxy at the same files). Dashy's own
config-loader always reduces a page's `path:` to its basename and reads it flat from its
user-data root — it never looks inside a `pages/` subfolder — so without that static
`/pages/` alias, switching to any page beyond the first fails with
`Unable to load config from '/pages/<file>.yml'`.

## Security model

- **HTTPS only** — plain HTTP redirects to HTTPS (self-signed cert generated by `generate-cert.sh`; swap in a CA/reverse-proxy cert for production).
- **Display screens are read-only & unauthenticated** — Dashy config editor disabled globally.
- **Admin surface protected** — `/admin` is guarded by Nginx basic auth (`.htpasswd`).
- **/health** endpoint for Docker health checks and external monitoring.

> Replace every `REPLACE_WITH_*` token and every `*.example.local` URL before going live.

## Installing an internal (CA-issued) TLS certificate

The installer creates a self-signed certificate, which browsers flag as
untrusted. To use a certificate from your internal PKI/CA, place the PEM files
at `nginx/certs/signage.crt` (server cert, with any intermediate CA appended
below it) and `nginx/certs/signage.key` (unencrypted private key), then
`docker compose restart nginx`. Filenames/paths are fixed — no Nginx edit needed.

**From a `.pfx` / `.p12`** (typical Windows CA export) — split it into PEM:

```bash
cd nginx/certs
openssl pkcs12 -in cert.pfx -nocerts -nodes -out signage.key   # private key
openssl pkcs12 -in cert.pfx -clcerts -nokeys -out signage.crt  # server cert
openssl pkcs12 -in cert.pfx -cacerts -nokeys -out chain.crt && cat chain.crt >> signage.crt  # append CA chain
chmod 600 signage.key && chmod 644 signage.crt
cd ../.. && docker compose restart nginx
```

**From existing `.crt` + `.key`** — copy them to `signage.crt` / `signage.key`
(append the intermediate CA to `signage.crt`), fix permissions as above, and
restart nginx.

Verify:

```bash
echo | openssl s_client -connect localhost:443 2>/dev/null | openssl x509 -noout -subject -issuer -dates
```

Notes: Nginx needs **PEM**, not PFX. The key must be **passphrase-free**
(`-nodes` strips it). In `signage.crt` the **server cert comes first**, then the
intermediate/CA. Include the access IP as a SAN in the cert if screens connect
by IP rather than hostname. Domain-joined PCs trust an internal-CA cert
automatically, so the browser warning disappears.

## Corporate network notes (TLS-inspection proxy)

Behind an SSL-inspecting proxy (e.g. Cisco Secure Access), install the corporate
root + intermediate CAs on the Pi so `git` and Docker pulls work:

```bash
sudo cp corp-root.crt corp-sub.crt /usr/local/share/ca-certificates/  # extension MUST be .crt
sudo update-ca-certificates                                            # expect "N added"
```

`.cer` files are ignored — rename them to `.crt` first. Never disable TLS
verification (`git config http.sslVerify false`).

## Zentrale Konfiguration: URLs und Zugangsdaten

Adressen und Geheimnisse stehen an **genau zwei Stellen** — nicht verstreut in
den YAML-Dateien. Beide sind gitignored und überleben damit jedes
`git reset --hard` / Update.

| Datei | Inhalt |
|---|---|
| `config/endpoints.env` | URLs der On-Prem-Dienste (Zabbix, vCenter, Firewall, Backup, Grafana, Cisco …) |
| `config/secrets.env` | API-Keys / Zugangsdaten (Zabbix-Token, Graph-Secret, Wetter-Key …) — `chmod 600` |

### Ablauf

```bash
cp config/endpoints.env.example config/endpoints.env
cp config/secrets.env.example   config/secrets.env && chmod 600 config/secrets.env
$EDITOR config/endpoints.env config/secrets.env

./scripts/render-config.py          # füllt alle *.tmpl -> fertige Configs
docker compose restart dashy nginx
```

`render-config.py` ersetzt `${VAR}` in jeder `*.tmpl` unter
`profiles/<profil>/` und `nginx/conf.d/extra/` und legt das Ergebnis ohne die
Endung `.tmpl` daneben (`conf.yml.tmpl` → `conf.yml`). Was noch keinen Wert hat,
**bleibt als `${VAR}` sichtbar stehen** und wird am Ende aufgelistet — man sieht
also sofort, was fehlt, statt eine still kaputte Config zu bekommen. Mit
`--check` läuft alles ohne zu schreiben, `--profile <name>` wählt ein anderes
Profil.

> Der Zabbix-API-Token landet über `nginx/conf.d/extra/zabbix-api.conf.tmpl` nur in
> der Nginx-Konfiguration im Container — er erreicht den Browser der Wand nie.

### Nach einem Update
```bash
./scripts/update.sh                 # holt, rendert, erzeugt Container neu
```

Das Skript ersetzt die drei Schritte von Hand — und macht den entscheidenden
vierten: `docker compose up -d --force-recreate`.

> **Warum `--force-recreate` nötig ist:** Einzelne Dateien (z. B. `conf.yml`)
> sind als Bind-Mount eingehängt, und ein Datei-Bind-Mount hängt an der *Inode*.
> `git pull` schreibt die Datei neu, damit bekommt sie eine neue Inode — der
> laufende Container zeigt weiter auf die alte und sieht den alten Stand. Ohne
> Neuerzeugung wirkt jedes Update wirkungslos, ohne dass irgendwo ein Fehler
> erscheint. (Für den CVE-Watcher ist stattdessen das ganze Verzeichnis
> gemountet, dort tritt das Problem nicht mehr auf.)

Von Hand entspricht das:
```bash
git reset --hard origin/<branch>    # config/*.env bleibt unangetastet
./scripts/render-config.py          # trägt deine Werte wieder ein
docker compose up -d --force-recreate
```

## Betriebslage — die eigentliche Wand

`https://<pi>/lage/`

Der Rest des Dashboards zeigt **Nachrichten über die Welt**. Diese Seite zeigt
**euren Zustand** — gemessen, nicht gemeldet. Genau das will man beim
Vorbeilaufen wissen.

Ganz oben steht **ein Satz**, aus fünf Metern lesbar:

| Lage | Anzeige |
|------|---------|
| alles läuft | ✓ **Alle Systeme laufen** — grün, ruhig |
| Warnungen | ! **3 Warnungen** — gelb, mit Namen |
| Ausfall | ✕ **vCenter gestört** — rot, pulsiert dezent |

Darunter Kennzahlen, dann jeder Dienst als Kachel mit Antwortzeit und
Verlaufslinie, gruppiert nach Bereich. **Gestörtes wandert automatisch nach
oben** — man muss nicht suchen.

### Was gemessen wird

Eine Zeile pro Dienst in `config/probes.txt` (Vorlage: `probes.txt.example`):

```
Name              | Gruppe           | Ziel
Zabbix            | Monitoring       | https://zabbix.example.local
DC01 LDAP         | Identity         | tcp://dc01.example.local:389
Interner DNS      | Netzwerk         | dns://intranet.example.local
```

Das Ziel bestimmt die Prüfart:

| Ziel | Geprüft wird |
|------|--------------|
| `https://…` | Statuscode, Antwortzeit **und Restlaufzeit des Zertifikats** |
| `http://…` | Statuscode, Antwortzeit |
| `tcp://host:port` | Port offen, Verbindungszeit (LDAP, SQL, SMTP, RDP …) |
| `dns://name` | Löst der Name auf, wie schnell |

Keine Zugangsdaten nötig. Die Sonde misst alle 60 Sekunden von sich aus.

> **Immer den vollen Namen eintragen.** `tcp://srvdemev00091o:389` schlägt fehl,
> `tcp://srvdemev00091o.firma.local:389` funktioniert. Ein Kurzname löst im
> Container nicht auf — die Suchdomäne des Firmennetzes kennt Docker nicht.
> (Deshalb scheitert auch `ping srvdemev00091o` auf dem Pi selbst.) Die Wand
> schreibt in dem Fall ausdrücklich „Kurzname löst nicht auf". Wer die
> Suchdomäne lieber einmal zentral setzt: `PROBE_DNS_SUFFIX=firma.local` in
> `.env`.

Drei Details, die den Unterschied machen:

- **HTTP 401/403 ist kein Ausfall.** Ein Dienst, der Anmeldung verlangt, *lebt*
  — die Kachel bleibt grün und schreibt „erreichbar, Anmeldung nötig". Ohne
  diese Unterscheidung wäre die halbe Wand dauerhaft rot und damit wertlos.
- **Ablaufende Zertifikate** stehen unten in der Fußzeile, ab 30 Tagen gelb, ab
  7 Tagen rot. Der Klassiker, der sonst erst am Ausfalltag auffällt.
- **Ausfälle sind Lücken in der Verlaufslinie**, keine Nullwerte — 0 ms sähe
  aus wie „besonders schnell".

### Einrichten

```bash
cp config/probes.txt.example config/probes.txt
nano config/probes.txt          # eure Dienste eintragen
./scripts/update.sh
```

Sofort nachsehen, ob die Ziele stimmen:
```bash
docker compose exec probe python /app/probe.py --once
```

## Warum die Nachrichtenseiten neu gebaut sind

Dashys RSS-Widget stapelt jede Meldung als Fließtext untereinander. Am
Schreibtisch ist das brauchbar, auf einer Wand aus fünf Metern eine Textwüste —
man erkennt nicht einmal, *welcher Anbieter* betroffen ist.

`/stoerungen/` macht daraus **eine Karte pro Anbieter**: Microsoft 365, Azure,
Cisco — jede mit klarem Status („✓ keine aktuelle Störung" / „! 2 aktuelle
Meldungen") und den letzten Einträgen mit Alter. Beim Vorbeilaufen zählt die
Frage *wer hat gerade ein Problem*, nicht die Chronologie aller Feeds.

**Frisch-Fenster je Zustand**, nicht pauschal:

| Zustand | sichtbar für | warum |
|---------|--------------|-------|
| Ausfall / Beeinträchtigung | 36 h | ein nachts begonnener Incident wäre mit 24 h schon wieder unsichtbar |
| Geplante Wartung | 12 h | sonst wochenlange Dauerwarnung |
| Behoben / abgesagt | 4 h | nur so lange, bis klar ist, warum es vorhin rot war |

**Einstufung über eine feste Rangfolge**, nicht über Stichwortzählen:
abgesagt → behoben → geplant → Ausfall → Beeinträchtigung → Info. Das ist der
eigentliche Trick — „Resolved: Major outage" enthält beide Begriffe, und ohne
diese Reihenfolge stünde ein längst erledigter Ausfall dauerhaft rot an der
Wand. Geprüft wird nur der **Titel**: Beschreibungstexte von Wartungsmeldungen
enthalten fast immer „impact" oder „degraded" und würden jede geplante Wartung
zum Ausfall machen.

**Fehlt ein Zeitstempel**, wird die Meldung weder verworfen noch als aktuell
angenommen, sondern als `? DATUM FEHLT` angezeigt — so wird ein Feed- oder
Parserproblem sichtbar statt still.

**Fällt eine Quelle aus**, steht das auf der Karte (`? QUELLE NICHT ERREICHBAR`
mit Grund) und der globale Zustand wechselt auf *Datenlage unvollständig* —
eine leere Karte darf nie wie „alles in Ordnung" aussehen. Der letzte
erfolgreiche Stand kommt aus `localStorage`, ausdrücklich als Zwischenspeicher
gekennzeichnet.

> **Wortwahl mit Absicht:** Die Wand sagt „Keine frische aktive Meldung", nicht
> „alles läuft". Die öffentlichen Feeds decken nur breit wirksame Störungen ab;
> was nur euren Tenant oder eine Region trifft, steht in Service Health. Die
> Wand darf keine Sicherheit behaupten, die die Quelle nicht hergibt.

Die Einstufung ist getestet — Grenzfälle wie „Resolved: Major outage" oder
„Maintenance cancelled due to ongoing incident" sieht man einer Seite im
Browser nicht an:

```bash
node scripts/test-stoerungen.mjs
```

Die Dashy-Seiten (`/`, `/security`, `/updates`) bleiben erreichbar, laufen aber
nicht mehr in der Rotation mit. Wieder aufnehmen: in `assets/signage.html` die
Zeile einkommentieren.

Die Rotation zeigt jetzt drei eigengestaltete Seiten:
`/lage/` (60 s) → `/stoerungen/` (30 s) → `/wall/` (30 s).

## Echte Websites auf der Wand — was geht und was nicht

Zwei Hürden, unabhängig voneinander:

**1. Einbetten wird blockiert.** Fremde Seiten senden `X-Frame-Options` oder
`CSP: frame-ancestors`. Der Browser zeigt dann eine weiße Fläche — ohne
Fehlermeldung. Lösung: die Seite über einen Nginx-Proxy unter der *eigenen*
Adresse ausliefern (wie `/zabbix/`), dort lässt sich die Kopfzeile entfernen.
Geht nur bei Seiten ohne Bot-Schutz und ohne Anmeldung.

**2. Lesbarkeit — die härtere Hürde.** Websites sind für 60 cm Leseabstand
gebaut. Die Wand steht 5 m weg. Ein 1:1-Abbild ist dort schlicht unlesbar,
auch wenn das Einbetten technisch klappt.

`/site/` löst das zweite Problem so weit es geht: Die Seite wird in einem
**schmalen Viewport** gerendert — dort schalten responsive Layouts in die
mobile Ansicht mit größeren Elementen — und das Ergebnis auf volle Wandbreite
hochskaliert. Menüs und Cookiebanner lassen sich oben wegschneiden.

```
/site/?url=/zabbix/zabbix.php?action=dashboard.view%26dashboardid=1%26kiosk=1
      &w=1100          Renderbreite: kleiner = größer skaliert
      &top=90          Pixel oben abschneiden (Menü)
      &title=Zabbix    Beschriftung
      &reload=300      Sekunden bis Neuladen
```

> **Die ehrliche Empfehlung:** Selbst gezoomt bleibt eine fremde Statusseite
> schlechter lesbar als dieselben Daten, aus dem Feed gezogen und groß
> gerendert — genau das macht `/stoerungen/`. Nimm `/site/` für **eure eigenen**
> Dashboards (Zabbix, Grafana), die ihr auf Wandgröße bauen könnt. Für fremde
> Statusseiten ist der Feed der bessere Weg.

## Zabbix an der Wand

Zwei Wege, beide ohne Token im Browser.

**1. Problemliste in der Betriebslage** — rechte Spalte von `/lage/`, mit
Schweregrad und Standzeit. Kommt automatisch, sobald `zabbix-api.conf`
gerendert ist (dafür braucht es `ZABBIX_API_TOKEN`). Fehlt sie, bleibt die
Spalte einfach weg — die Dashboards laufen davon unabhängig.

**2. Euer eigenes Zabbix-Dashboard als Vollbild.** Genau die Idee, eigene
Dashboards in Zabbix zu bauen und anzeigen zu lassen — das ist der direkteste
Weg zu echtem Inhalt.

> **Warum ein `<iframe>` auf Zabbix leer bleibt:** Zabbix sendet
> `X-Frame-Options: SAMEORIGIN`. Der Browser blockt die Einbettung wortlos —
> keine Fehlermeldung, nur eine weiße Fläche. Deshalb läuft Zabbix über
> `location /zabbix/` unter **unserer** Adresse (damit same-origin), und Nginx
> entfernt die Kopfzeile zusätzlich. Erst dadurch wird das Bild sichtbar.

Einrichten:

1. `ZABBIX_URL` in `config/endpoints.env` — **immer der volle Name (FQDN)**,
   nicht `zabbix`, sondern `zabbix.firma.local`. Notfalls die IP.
   `ZABBIX_API_TOKEN` in `config/secrets.env` (Zabbix: *Users → API tokens*,
   nur-lesende Rolle genügt) — nur für die Problemliste, **nicht** fürs
   Einbetten von Dashboards.
2. `./scripts/update.sh`
3. **`./scripts/check-zabbix.sh`** — prüft DNS auf dem Pi, DNS im Container,
   Port, TLS, X-Frame-Options, API-Token und den Proxy einzeln. Bei der ersten
   roten Zeile ansetzen; alles darunter ist Folgefehler.
4. In Zabbix das Dashboard bauen und die `dashboardid` aus der URL merken
5. Damit ohne Anmeldung etwas zu sehen ist, **eines von beiden**:
   Dashboard mit dem Benutzer `guest` teilen (*Sharing → Public*), oder einen
   Nur-Lese-Benutzer anlegen und HTTP-Auth verwenden
6. In `assets/signage.html` die Zabbix-Zeile einkommentieren und die
   `dashboardid` eintragen

### Die drei Stellen, an denen es typischerweise scheitert

| Symptom | Ursache | Behebung |
|---------|---------|----------|
| `/zabbix/` → **500 / 502** | nginx löst den Namen im Container nicht auf | FQDN statt Kurzname in `ZABBIX_URL`; hilft das nicht: `EXTRA_HOST_1=name.firma.local:10.0.0.42` in `.env` |
| iframe **leer, keine Fehlermeldung** | direkt auf `https://zabbix…` eingebettet statt über `/zabbix/` | immer `/zabbix/…` verwenden — nur dort wird `X-Frame-Options` entfernt |
| `/zabbix/` → **404** | `zabbix-ui.conf` nicht gerendert oder nginx nicht neu gestartet | `./scripts/render-config.py && ./scripts/update.sh` |
| API liefert **HTML** statt JSON (`You are not logged in`) | in `ZABBIX_URL` steht eine komplette Dashboard-URL statt der Basis | nur `http://server.firma.local/zabbix` eintragen |
| API: **No permissions to call** | Token gültig, aber die *Rolle* erlaubt den Aufruf nicht | *Users → User roles →* Rolle: `API` auf **Enabled**, Allow list leer (= alle Methoden); dazu *Permissions* mit Read auf die Hostgruppen |

`ZABBIX_URL` allein reicht fürs Einbetten. Der API-Token wird nur für die
Problemliste auf `/lage/` gebraucht — deshalb sind es zwei getrennte Dateien
(`zabbix-ui.conf.tmpl` / `zabbix-api.conf.tmpl`). Fehlt der Token, wird nur die
API-Datei übersprungen, die Dashboards laufen trotzdem.

Direkt prüfen — im Browser des Pi:
`https://<pi>/zabbix/zabbix.php?action=dashboard.view&dashboardid=1&kiosk=1`

`kiosk=1` blendet Menü und Kopfzeile aus.

### Was wie lange läuft — `config/pages.txt`

Die Seitenliste steht **nicht** im Quelltext, sondern in `config/pages.txt`.
Der Grund: `assets/signage.html` ist versioniert — eine Änderung dort wäre beim
nächsten `git reset --hard` weg. Diese Datei ist gitignored und überlebt jedes
Update.

```
# Name | Adresse | Sekunden
Betriebslage | /lage/       | 60
Störungen    | /stoerungen/ | 30
Zabbix 419   | /zabbix/zabbix.php?action=dashboard.view&dashboardid=419&kiosk=1 | 60
```

Sekunden weglassen = 30 s. Zeile löschen oder `#` davor blendet eine Seite aus.
Nach dem Bearbeiten genügt `docker compose restart nginx` — kein Neubau.

Ist die Datei nicht lesbar oder komplett auskommentiert, greift eine
eingebaute Rückfallebene (Betriebslage / Störungen / Sicherheit). Eine leere
Datei darf die Wand nicht schwarz schalten.

### Mehrere Zabbix-Dashboards

Einfach mehrere Zeilen. Drei Regeln:

1. **Immer mit `/zabbix/` beginnen**, nie mit `http://server/…` — nur über den
   Proxy läuft Zabbix unter eurer Adresse.
2. **`&kiosk=1` anhängen** — blendet Menü und Kopfzeile aus.
3. Das Dashboard muss mit dem Benutzer `guest` geteilt sein
   (*Dashboard → Sharing → Public*), sonst kommt der Login.

`from=now-1h&to=now` steuert den Zeitraum und darf mit dran. Ist die Schrift aus
fünf Metern zu klein, dieselbe Seite über `/site/` hochskalieren — Beispielzeile
steht in `pages.txt.example`.

## CVE-Watcher: Webhook bei relevanten Schwachstellen

Meldet **externe** Schwachstellen, die **eure** Produkte betreffen — mit echtem
CVSS, nicht mit Stichwortraten.

```
Advisory-Feeds (BSI, CISA, Cisco PSIRT, Fortinet, VMware + eigene)
   -> CVE-IDs extrahieren
   -> Watchlist-Abgleich (config/watchlist.txt)   "betrifft uns das?"
   -> CVSS von der NVD-API + KEV-Abgleich          "wie schlimm ist es wirklich?"
   -> Advisories gruppieren, Gedächtnis abgleichen "ist das neu?"
   -> EIN gebündelter POST je Durchlauf, fertig formatiert
```

### Takt und Gedächtnis — die zwei häufigsten Fragen

**Wie oft läuft er?** Alle **30 Minuten** (`CVE_POLL_SECONDS=1800` in `.env`),
plus einmal sofort beim Start des Containers. Findet ein Durchlauf nichts
Neues, wird auch **nichts gesendet** — es gibt keine „alles ruhig"-Meldung.

**Meldet er nur Neues?** Ja. Jede CVE wird **genau einmal** gemeldet; danach
steht sie in `state/seen.json` und wird in allen folgenden Durchläufen
übersprungen — auch wenn sie wochenlang in den Feeds bleibt. Was du
bekommst, ist der Zuwachs, nicht der Bestand.

Vier Details dazu, die im Betrieb zählen:

- **Probelauf und Echtbetrieb führen getrennt Buch** (`seen-dryrun.json` vs.
  `seen.json`). Sonst hätte ein Testlauf die Funde als „erledigt" abgehakt und
  der erste scharfe Lauf wäre stumm geblieben.
- **Erst bei erfolgreicher Zustellung** gilt etwas als gemeldet. Antwortet der
  Empfänger nicht, bleibt das Gedächtnis unverändert und der nächste Durchlauf
  versucht es erneut. Nichts geht still verloren.
- **`CVE_MAX_PER_RUN` (10)** deckelt jeden Durchlauf. Ein Rückstand wird über
  mehrere Läufe abgebaut, nicht auf einmal.
- **`state/seen.json` nicht löschen**, sobald der Watcher scharf ist — sonst
  gilt der gesamte Bestand wieder als neu.

### Priorisierung
| Bedingung | Priorität |
|---|---|
| CVE steht in CISAs KEV (**nachweislich ausgenutzt**) | **P1** — unabhängig vom Score |
| CVSS >= 9.0 | **P1** |
| CVSS >= `CVE_MIN_CVSS` (Standard 7.0) | **P2** |
| darunter | P3 — wird nicht gesendet, nur als gesehen vermerkt |

### Payload

Ein Aufruf je Durchlauf mit allen Funden:

```json
{
  "event": "vulnerability.batch",
  "detected_at": "2026-09-09T05:12:56+00:00",
  "highest_priority": "P1",
  "summary": {
    "total": 4, "p1": 3, "p2": 1,
    "kev_count": 3, "kev_cves": ["CVE-2026-20127", "…"],
    "products": ["catalyst", "cisco"],
    "headline": "4 neue Meldungen mit 10 CVEs (3x P1, 1x P2, 3x aktiv ausgenutzt)",
    "text":     "… Klartext für E-Mail und Ticket …",
    "markdown": "… für Slack …",
    "html":     "… für Teams 'Post message' …"
  },
  "card": { "type": "AdaptiveCard", "…": "fertig für Teams" },
  "findings": [
    {
      "priority": "P1",
      "cve": "CVE-2026-20127",
      "cves": ["CVE-2026-20127", "CVE-2026-20182", "CVE-2026-20245"],
      "cve_count": 3,
      "cvss": { "score": 10.0, "severity": "CRITICAL", "vector": "…", "source": "NVD" },
      "kev": { "listed": true, "due_date": "2026-09-18", "known_ransomware": "Known" },
      "matched_products": ["catalyst", "cisco"],
      "title": "Cisco Catalyst SD-WAN … Privilege Escalation Vulnerability",
      "source": "Cisco PSIRT",
      "published": "2026-09-05 10:00:00.0",
      "link": "https://sec.cloudapps.cisco.com/…"
    }
  ]
}
```

### Einrichten
1. **Watchlist pflegen** — `config/watchlist.txt`: eine Zeile je Produkt/Hersteller,
   den ihr einsetzt. Ohne Treffer keine Meldung; das ist der Unterschied zwischen
   „jede CVE der Welt" und „das betrifft uns".
2. **Ziel eintragen** — `CVE_WEBHOOK_URL` (+ optional `CVE_WEBHOOK_AUTH_HEADER`)
   in `config/secrets.env`. Ein **NVD-API-Key** (kostenlos) beschleunigt die
   CVSS-Abfragen deutlich; ohne Key wartet der Watcher 7 s je CVE.
3. **Zustellung prüfen, ohne auf einen echten Fund zu warten:**
   ```bash
   docker compose exec cve-watcher python /app/watch.py --test-webhook
   ```
   Sendet einen erfundenen Fund in **derselben Struktur** wie im Echtfall — so
   baut ihr die Logic App nicht gegen eine Form, die später nie ankommt. Der
   Payload trägt `"event": "vulnerability.test"`; darauf lässt sich im
   Zielsystem filtern, damit Tests kein Ticket erzeugen.
4. **Erst beobachten** — der Dienst startet mit `CVE_DRY_RUN=true` und schreibt
   nur ins Log:
   ```bash
   docker compose logs -f cve-watcher
   docker compose exec cve-watcher python /app/watch.py --once   # einmal jetzt
   ```
   Wenn die richtigen Meldungen auftauchen, scharf schalten:
   ```bash
   sed -i 's/^CVE_DRY_RUN=true/CVE_DRY_RUN=false/' .env
   ./scripts/update.sh
   ```
   In der Startzeile muss dann `DRY_RUN=False` und `Gedaechtnis=/state/seen.json`
   stehen. Steht der Schlüssel gar nicht in `.env`, greift lautlos der
   Vorgabewert — `./scripts/update.sh --env-ergaenzen` trägt fehlende nach.
5. **Eigene Quellen ergänzen** — `config/cve-feeds.txt` (`Name | URL`). Feed-
   Adressen veralten; prüfen mit `./scripts/check-feeds.sh --kandidaten`.
   Antwortet eine Quelle mit HTML statt XML, sagt das Log das ausdrücklich.

### Alle Stellschrauben

| Schlüssel in `.env` | Standard | Wirkung |
|---|---|---|
| `CVE_POLL_SECONDS` | `1800` | Abstand zwischen zwei Durchläufen |
| `CVE_DRY_RUN` | `true` | `true` schreibt nur ins Log, sendet nichts |
| `CVE_MIN_CVSS` | `7.0` | ab hier P2; darunter nur vermerkt, nicht gemeldet |
| `CVE_MAX_PER_RUN` | `10` | höchstens so viele Funde je Durchlauf |
| `CVE_BATCH` | `true` | ein gebündelter Aufruf statt einer je CVE |
| `CVE_ADAPTIVE_CARD` | `true` | fertige Teams-Karte unter `card` mitschicken |

Geheimnisse gehören nach `config/secrets.env`: `CVE_WEBHOOK_URL`,
`CVE_WEBHOOK_AUTH_HEADER`, `NVD_API_KEY`.

### Warum Dry-Run zuerst
Ein Webhook-Sender alarmiert aktiv. Beim ersten Lauf sind alle CVEs neu — ohne
Bremse gäbe das einen Schwall. Deshalb: Dry-Run als Standard,
`CVE_MAX_PER_RUN` (10) als Deckel und ein Dedup-Gedächtnis unter `state/`,
damit jede CVE genau einmal meldet.

### Webhook-Empfänger: was ihr bereitstellen müsst

**Der Watcher sendet nur — einen Empfänger bringt er nicht mit.** `CVE_WEBHOOK_URL`
muss auf einen Endpoint zeigen, der HTTP POST mit JSON annimmt. Optionen:

| Ziel | Eignung |
|---|---|
| **Ticketsystem** mit Inbound-Webhook/REST-API | am saubersten — jede P1 wird ein Ticket |
| **n8n / Node-RED / Power Automate** | nimmt generisches JSON und verteilt weiter (Mail, Teams, Ticket) — flexibelster Weg |
| **Alerting-Tool** (Opsgenie, PagerDuty, Alerta …) | wenn ihr sowas schon habt |
| **`scripts/test-webhook-receiver.py`** | nur zum Testen: schreibt eingehendes JSON ins Terminal |

> **Für Teams ist der Zwischenschritt inzwischen erledigt:** Der Payload bringt
> unter `card` eine fertige Adaptive Card und unter `summary.html` eine
> Teams-taugliche HTML-Fassung mit. In der Logic App genügt damit ein einziges
> Feld — siehe *Konkret in der Logic App*.

**Historischer Hinweis.** Teams akzeptiert kein freies
JSON, sondern erwartet eine Adaptive Card, und die klassischen
Office-365-Connector-Webhooks werden abgelöst. Der übliche Weg ist ein
**Power-Automate-Flow** („Wenn eine HTTP-Anfrage empfangen wird" → Nachricht
posten): der Flow nimmt unser JSON und baut die Karte. Alternativ baue ich einen
Teams-Formatter direkt in den Watcher ein — sag Bescheid, wenn das das Ziel ist.

Zum Ausprobieren ohne jede Anbindung:

```bash
./scripts/test-webhook-receiver.py 9000
# in config/secrets.env:  CVE_WEBHOOK_URL=http://172.17.0.1:9000/hook
```

### Ein Aufruf statt zehn

Standardmäßig geht **ein Webhook je Durchlauf** raus, der alle Funde enthält —
nicht einer je CVE. Bei einem Rückstand wären das sonst zehn Aufrufe
hintereinander, und eine Flut stumpft ab, bis niemand mehr hinsieht.

```json
{
  "event": "vulnerability.batch",
  "highest_priority": "P1",
  "summary": {
    "total": 4, "p1": 1, "p2": 3,
    "kev_count": 1, "kev_cves": ["CVE-2026-11111"],
    "products": ["cisco", "fortinet"],
    "headline": "4 neue Schwachstellen (1x P1, 3x P2, 1x aktiv ausgenutzt)"
  },
  "findings": [ { "cve": "...", "priority": "...", "cvss": {...}, ... } ]
}
```

`summary` und `highest_priority` stehen bewusst oben: Damit entscheidet die
Logic App über eine Weiterleitung, **ohne** die Liste durchgehen zu müssen.

### Fertig formatiert — im Zielsystem wird kein Text gebaut

| Feld | wofür |
|---|---|
| `summary.headline` | Betreffzeile: *„3 neue Meldungen mit 9 CVEs (2x P1, 1x P2, 1x aktiv ausgenutzt)"* |
| `summary.text` | Klartext für E-Mail oder Ticket, nach Dringlichkeit sortiert |
| `summary.html` | für Teams *Post message* — Markdown verliert dort die Umbrüche |
| `summary.markdown` | für Teams oder Slack: Titel als klickbare Überschrift, darunter eine Zeile Dringlichkeit/CVSS/Produkte |
| `highest_priority` | `P1`/`P2` — für die Weiterleitungsregel |
| `summary.kev_cves` | aktiv ausgenutzt: das schärfste Signal |

### Konkret in der Logic App

Der Payload wird **nicht** als Ganzes weitergereicht — dann steht das rohe JSON
in der Nachricht. Du greifst genau ein Feld heraus:

| Ziel | Ausdruck |
|---|---|
| **Teams (empfohlen)** – *Post adaptive card* | `@{triggerBody()?['card']}` |
| Teams als Text – *Post message* | `@{triggerBody()?['summary']?['html']}` |
| E-Mail – Betreff | `@{triggerBody()?['summary']?['headline']}` |
| E-Mail – Text | `@{triggerBody()?['summary']?['text']}` |
| Nur bei P1 weiterleiten – Bedingung | `@equals(triggerBody()?['highest_priority'], 'P1')` |
| Nur bei aktiv ausgenutzt | `@greater(triggerBody()?['summary']?['kev_count'], 0)` |

> **Warum HTML und nicht Markdown bei *Post message*:** Der Teams-Connector
> verwirft dort die Zeilenumbrüche — alles läuft zu einem Absatz zusammen und
> die Trennlinien landen mitten im Text. HTML rendert er zuverlässig.
> `summary.markdown` bleibt für Slack und alles andere.

**`card` ist eine fertige Adaptive Card (1.4)** — Kopfzeile, Kennzahlen als
FactSet, je Meldung ein Block mit Dringlichkeitsfarbe, klickbar zum Advisory.
Sie geht unverändert an *Post adaptive card in a chat or channel*. Kein
JSON-Zusammenbau in der Logic App: genau die Stelle, an der solche Ketten
sonst brechen.

Brauchst du sie nicht: `CVE_ADAPTIVE_CARD=false` in `.env` spart etwa die
Hälfte der Nutzlast.

### Ein Advisory ist eine Meldung, nicht zwölf

Cisco veröffentlicht Sammel-Advisories: ein ClamAV-Eintrag behebt sieben CVEs.
Als sieben Einträge gelesen wirkt das wie sieben Vorfälle und bläht jede
Benachrichtigung auf. Meldungen mit gleichem Link werden darum **gruppiert** —
mit allen CVEs in `cves`, der höchsten Einstufung und dem höchsten Score. Aus
den 10 Einträgen eines echten Laufs werden so 3 Meldungen.

`cve` bleibt als Einzelfeld erhalten (die dringendste der Gruppe), damit
vorhandene Regeln im Zielsystem weiter greifen.

### So sieht es am Ende aus

`summary.markdown` (Slack) bzw. `summary.html` (Teams) liefern das hier fertig:

```
4 neue Meldungen mit 10 CVEs (3x P1, 1x P2, 3x aktiv ausgenutzt)

Cisco Secure Firewall Management Center Authentication Bypass
🔴 P1 · CVSS 10.0 · cisco · gestern
CVE-2026-20079

Cisco Catalyst SD-WAN Privilege Escalation
🔴 P1 · CVSS 10.0 · ⚠️ aktiv ausgenutzt · catalyst, cisco · vor 4 Tagen
CVE-2026-20127, CVE-2026-20182, CVE-2026-20245
```

Der Titel ist klickbar und führt direkt zum Advisory.

### Was die Darstellung lesbar hält

Drei Entscheidungen, die den Unterschied machen:

- **Tracking-Anhang der URL weg.** Cisco hängt an jede Advisory-Adresse einen
  langen RSS-Herkunftsparameter — eine Zeile Kauderwelsch pro Meldung. Der Link
  funktioniert ohne genauso.
- **Höchstens vier CVE-Nummern sichtbar**, danach „+ 5 weitere". Neun Nummern
  nebeneinander liest niemand; die vollständige Liste steht ohnehin in `cves`.
- **Titel zuerst**, als klickbare Überschrift. Das ist die Information, nach der
  man sucht — Dringlichkeit, CVSS und betroffene Produkte stehen darunter in
  *einer* Zeile.
- **Datum als Alter.** „vor 4 Tagen" beantwortet die Frage, um die es geht —
  *ist das frisch?* Ein Datum allein muss man erst umrechnen. Im Klartext steht
  beides (`08.09.2026 (gestern)`), weil ein Ticket ein festes Datum braucht.
  Die drei Feed-Formate — RFC-822, ISO und Ciscos Eigenbau — werden dabei
  vereinheitlicht.

Ebenfalls behoben: Die Produkterkennung suchte den Watchlist-Begriff irgendwo
im Text. „exchange" traf damit auch in „data exchanged", „cisco" in
„franciscoNet". Jetzt wird auf Wortgrenzen geprüft.

Schlägt die Zustellung fehl, gilt **kein** Fund als gemeldet — der nächste
Durchlauf versucht es erneut. Nichts geht still verloren.

Einzelversand (ein Aufruf je CVE) mit `CVE_BATCH=false` in `.env`.
`--test-webhook` sendet dieselbe Struktur, damit die Logic App nicht gegen
eine Form gebaut wird, die später nie ankommt.

## Alert-Wand (`/wall/`)

Eine eigengestaltete Seite außerhalb von Dashys Kartenraster, weil der Browser
fremde Feeds nicht direkt laden darf (CORS). Nginx holt sie serverseitig und
liefert sie same-origin unter `/feeds/<id>` aus — erst dadurch ist freies
Layout möglich: KPI-Zeile (24 h), nach Schweregrad sortierter Meldungsstrom,
Live-Uhr, Quellen-Gesundheit, Auto-Refresh alle 5 Minuten.

### Quellen ändern
`assets/feeds.json` (ausgeliefert unter `/tiles/feeds.json`) steuert, welche
Quellen die Wand zeigt — `enabled: false` blendet eine aus, ohne sie zu löschen.
Jede `id` braucht eine passende `location = /feeds/<id>` in
`nginx/conf.d/dashy.conf`. Prüfen, ob alle Endpunkte echte Feeds liefern:

```bash
./scripts/check-feeds.sh https://localhost
```

### Einstufung: belastbar vor Heuristik
Nennt eine Meldung eine CVE, die in CISAs **KEV-Katalog** (`/feeds/kev`) steht,
gilt sie als *kritisch — aktiv ausgenutzt*; das ist eine autoritative Quelle,
keine Textanalyse. Nur ohne KEV-Treffer greift eine Stichwort-Heuristik über
Titel/Text. Der Schweregrad trägt immer Symbol + Label, nie Farbe allein.

### Zabbix-Alarme einblenden
Der API-Token gehört nicht in eine Seite, die im Flur läuft — Nginx hängt ihn
serverseitig an. Nichts von Hand kopieren: `ZABBIX_URL` in
`config/endpoints.env`, `ZABBIX_API_TOKEN` in `config/secrets.env`, dann
`./scripts/update.sh`. Danach in `assets/wall.html` `ZABBIX_ENABLED = true`
setzen. Echte Alarme stehen dann immer vor den News.

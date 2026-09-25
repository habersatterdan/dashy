# Inbetriebnahme — zum Kopieren

Diese Anleitung bringt den Pi vom aktuellen Stand auf den fertigen Stand.
**Von oben nach unten durchgehen.** Jeder Block ist so gebaut, dass er
gefahrlos mehrfach laufen kann.

Angenommen wird, dass das Repo unter `~/dashy` liegt. Falls nicht:
`cd` auf euren Pfad anpassen.

---

## Schritt 0 — Warum die Reihenfolge wichtig ist

`./scripts/update.sh` startet am Ende die Container. Drei Dienste
(`connect`, `m365`, `cve-watcher`) lesen `config/secrets.env`. **Fehlt diese
Datei, bricht Docker Compose ab**, bevor irgendetwas startet.

Deshalb: **erst die Vorlagen kopieren, dann updaten.** Genau in dieser
Reihenfolge stehen die Schritte unten.

---

## Schritt 1 — Stand holen, aber noch nicht starten

```bash
cd ~/dashy
git fetch origin claude/noc-signage-raspberry-pi-ea7gg2
git reset --hard origin/claude/noc-signage-raspberry-pi-ea7gg2
```

> `git reset --hard` löscht **nichts** aus `config/` — alle eure eigenen
> Dateien dort sind gitignored und überleben jedes Update. Genau dafür
> liegen sie da.

---

## Schritt 2 — Alle Konfigurationsdateien anlegen

Legt jede fehlende Datei aus ihrer Vorlage an und lässt vorhandene in Ruhe:

```bash
cd ~/dashy
for f in config/*.example; do
  ziel="${f%.example}"
  [ -f "$ziel" ] || { cp "$f" "$ziel"; echo "angelegt: $ziel"; }
done
[ -f .env ] || cp .env.example .env
chmod 600 config/secrets.env
ls -l config/
```

Danach fehlende Schalter in eure bestehende `.env` nachziehen (bestehende
Werte bleiben unberührt, Sicherung landet in `.env.bak`):

```bash
./scripts/update.sh --env-ergaenzen
```

> **Warum das nötig ist:** Ein *fehlender* Schlüssel in `.env` wirkt wie ein
> absichtlich gesetzter Vorgabewert. Neue Schalter landen nur in
> `.env.example`, nicht automatisch in eurer `.env`.

---

## Schritt 3 — Prüfen, ob die Benutzerkennung stimmt

Die Hintergrunddienste laufen nicht als `root`. Passt die Kennung nicht,
startet alles, aber nichts wird gespeichert — und das fällt erst Tage später
auf.

```bash
id            # merken: uid=… gid=…
grep -E '^RUN_(UID|GID)=' ~/dashy/.env
```

Stimmen die Zahlen nicht überein, in `.env` korrigieren:

```bash
nano ~/dashy/.env      # RUN_UID / RUN_GID auf die Ausgabe von "id" setzen
```

---

## Schritt 4 — Update fahren

Das ist der eigentliche Befehl. Er holt den Stand, rendert die
nginx-Konfiguration, baut die Grafana-Dashboards, richtet die Rechte auf
`./state` ein und **erzeugt die Container neu**:

```bash
cd ~/dashy
./scripts/update.sh
```

> Ein reines `git pull` reicht nicht. Einzelne Dateien sind als Bind-Mount
> eingehängt und hängen an ihrer Inode — Git schreibt sie neu, der Container
> sähe weiter den alten Stand. `update.sh` löst genau das.

Am Ende müssen alle Dienste `running` sein:

```bash
docker compose ps
```

`shotter` und `watchtower` fehlen dort absichtlich — die starten nur auf
Wunsch (siehe ganz unten).

---

## Schritt 5 — Gesamtprüfung

```bash
cd ~/dashy
./scripts/status.sh
```

**Das ist der Maßstab.** Das Skript prüft Betrieb *und* Sicherheit — unter
anderem mit einer echten Gegenprobe zur Laufzeit, ob der Zabbix-Proxy
schreibende Befehle wirklich abweist.

Dazu die Wandseiten einzeln:

```bash
./scripts/check-wall.sh
```

Wenn hier etwas rot ist: **erst das beheben**, bevor ihr weitermacht. Die
folgenden Schritte bauen darauf auf.

---

## Schritt 6 — Die neue Seite in die Rotation

`/kennzahlen/` ist neu. In eurer bestehenden `config/pages.txt` steht sie
noch nicht:

```bash
cd ~/dashy
grep -q '/kennzahlen/' config/pages.txt \
  || printf '%-17s | %-14s | %s\n' 'Kennzahlen' '/kennzahlen/' '40' >> config/pages.txt
docker compose restart nginx
```

Ansehen: `https://<pi>/kennzahlen/`

Solange nichts angebunden ist, erklärt die Seite selbst, wie man etwas
hinzufügt. Das ist Absicht — eine leere Seite auf der Wand wäre ein Rätsel.

---

## Schritt 7 — LOGINventory und Jira anbinden

```bash
cd ~/dashy
./scripts/add.sh anwendung
```

Das Skript fragt alles ab und **probiert die Anbindung sofort aus**. Was ihr
vorher bereitlegen solltet:

| Was | Beispiel |
|---|---|
| Die Adresse, die JSON liefert | `https://loginv.firma.local/api/odata/Device?$count=true&$top=0` |
| Benutzer/Token | am besten ein **eigener, nur lesender** Zugang |
| Den Pfad zum Wert | `@odata.count` bei LOGINventory, `total` bei Jira |

**Den Pfad findet ihr so:** Adresse einmal im Browser öffnen und in die
Antwort sehen. Steht dort `{"@odata.count": 1284, …}`, ist der Pfad
`@odata.count`.

Stimmt der Pfad nicht, bricht das Skript sofort ab und nennt die Schlüssel,
die wirklich in der Antwort stehen. Ihr müsst also nicht raten.

Nachträglich ändern und erneut prüfen:

```bash
nano config/connect.ini
docker compose exec connect python /app/connect.py --test          # alle
docker compose exec connect python /app/connect.py --test jira     # eine
docker compose restart connect
```

> **Zugangsdaten:** In `config/connect.ini` steht nie ein Passwort, nur der
> *Name* einer Variablen aus `config/secrets.env`. `add.sh` fragt den Wert
> unsichtbar ab und legt ihn selbst ab. Die `connect.ini` könnt ihr
> bedenkenlos einem Kollegen zeigen.

---

## Schritt 8 — Microsoft 365 (wenn gewünscht)

Braucht eine App-Registrierung in Entra. Schritt für Schritt:
[`docs/M365.md`](M365.md).

```bash
nano ~/dashy/config/secrets.env    # M365_TENANT_ID / _CLIENT_ID / _CLIENT_SECRET
docker compose restart m365
docker compose exec m365 python /app/health.py --test
```

**Prüft in Entra, dass wirklich nur `ServiceHealth.Read.All`
(Anwendungsberechtigung) eingetragen ist.** Das bei der Registrierung
automatisch vergebene `User.Read` gehört entfernt.

**Ablaufdatum des Client-Secrets in den Kalender.** Läuft es ab, bleibt die
Karte leer und der Grund steht nur im Log.

---

## Schritt 9 — CVE-Watcher scharf schalten

Er startet bewusst im Trockenlauf: schreibt nur ins Log, sendet nichts.

```bash
cd ~/dashy
docker compose exec cve-watcher python /app/watch.py --once   # erst ansehen
nano config/secrets.env                                        # CVE_WEBHOOK_URL
nano .env                                                      # CVE_DRY_RUN=false
docker compose up -d --force-recreate cve-watcher
```

> Trockenlauf und Echtbetrieb haben **getrennte Gedächtnisdateien**. Der
> erste echte Lauf ist also nicht stumm, nur weil vorher ein Trockenlauf
> alles als „gesehen" markiert hat.

---

## Schritt 10 — Altlasten aus `config/` entfernen

Die Dateien unter `config/` sind gitignored. Genau deshalb überleben sie jedes
Update — **aber eben auch die Beispielwerte, mit denen ihr angefangen habt.**
Auf der Wand sieht das aus wie ein Ausfall: „example.local nicht erreichbar"
ist kein Fehler, sondern eine Karteileiche.

```bash
cd ~/dashy
./scripts/aufraeumen.sh
```

Zeigt nur an, ändert nichts. Geprüft wird:

| Was | Gefunden wird |
|---|---|
| `probes.txt` | Beispielziele auf `example.local` |
| `endpoints.env` | Adressen, die noch auf `example.local` zeigen |
| `pages.txt` | Wandseiten, die nicht mehr laden |
| alle Listen | doppelte Einträge |
| `gruppen.txt` | Hostgruppen, die Zabbix gar nicht kennt |
| `connect.ini` | Anbindungen, die keinen Wert liefern |
| überall | Sicherungen älter als 30 Tage |

Übernehmen:

```bash
./scripts/aufraeumen.sh --anwenden
./scripts/update.sh
```

**Es wird nichts gelöscht.** Beanstandete Zeilen werden mit `#` stillgelegt,
mit der Begründung darüber, und die Datei vorher nach `<name>.bak` gesichert.
Falsch getroffen? Zurück mit einem Handgriff:

```bash
cp config/probes.txt.bak config/probes.txt
```

Drei Punkte bleiben bewusst von Hand: **Adressen**, **Wandseiten** und
**Hostgruppen**. Dort steckt eine Entscheidung drin — ein leerer Wert in
`endpoints.env` bedeutet „diesen Platz weglassen" und ist etwas anderes als ein
falscher Wert. Das kann kein Skript für euch entscheiden.

---

## Kurzfassung zum Abtippen

Wenn alles schon eingerichtet ist und ihr nur den neuen Stand wollt:

```bash
cd ~/dashy
for f in config/*.example; do [ -f "${f%.example}" ] || cp "$f" "${f%.example}"; done
chmod 600 config/secrets.env
./scripts/update.sh --env-ergaenzen
./scripts/update.sh
./scripts/aufraeumen.sh
./scripts/status.sh
```

---

## Wenn etwas klemmt

| Symptom | Befehl |
|---|---|
| Ein Dienst startet nicht | `docker compose logs --tail 50 <dienst>` |
| Wandseite lädt nicht | `./scripts/check-wall.sh` |
| Zabbix zeigt nichts | `./scripts/check-zabbix.sh` |
| Grafana leer | `./scripts/check-grafana.sh` |
| Feeds leer | `./scripts/check-feeds.sh` |
| Kennzahl fehlt | `docker compose exec connect python /app/connect.py --test` |
| Platzhalter ohne Wert | `./scripts/render-config.py` — nennt Datei und Schlüssel |

**nginx in der Neustartschleife, alles andere „keine Antwort":** Das ist *ein*
Fehler, nicht zwölf — nginx liefert jede Wandseite aus. Die Ursache steht immer
im Log:

```bash
docker compose logs --tail 20 nginx
```

Sagt es `chown("/var/cache/nginx/…") failed (1: Operation not permitted)`, fehlt
dem Container die Capability `CHOWN` (in `docker-compose.yml` unter `nginx:` →
`cap_add`). Seit dem 25.09.2026 ist sie drin; ältere Stände brauchen
`./scripts/update.sh`.

**Compose bricht sofort ab mit `env file … not found`:** Schritt 2 wurde
übersprungen. Vorlagen kopieren, dann erneut.

**Alles sieht gut aus, aber `./state` bleibt leer:** `RUN_UID`/`RUN_GID` in
`.env` passen nicht zu `id`. Schritt 3.

---

## Was absichtlich nicht mitstartet

```bash
docker compose --profile screenshots up -d    # Chromium rendert fremde Seiten
docker compose --profile auto-update up -d    # Watchtower braucht den Docker-Socket
```

Beides sind bewusste Entscheidungen, keine Vergesslichkeit — die Begründung
steht in [`docs/SICHERHEIT.md`](SICHERHEIT.md).

# Die Wand bedienen

Eine Seite für alle im Team. Kein Vorwissen nötig — für jede Aufgabe genügt
**ein Befehl**.

Anmelden am Pi:

```bash
ssh itzd@itzd-dashboard
cd ~/dashy
```

---

## Der eine Befehl, der fast alles kann

```bash
./scripts/add.sh
```

Fragt, was du hinzufügen willst, stellt zwei bis drei Fragen und macht den
Rest — inklusive Prüfung, ob es danach wirklich lädt.

```
Was möchtest du zur Wand hinzufügen?
  1) Zabbix-Dashboard
  2) Interne Weboberfläche (Grafana, PRTG, CheckMK, Wiki ...)
  3) Nachrichtenquelle (RSS/Atom)
  4) Grafana-Dashboard von diesem Pi
  5) Nur anzeigen, was schon drin ist
```

---

## Aufgabe 1 — Ein Zabbix-Dashboard auf die Wand

1. Dashboard in Zabbix öffnen
2. **Adresse aus der Adresszeile kopieren** (die ganze, mit `dashboardid=…`)
3. Auf dem Pi:

```bash
./scripts/add.sh zabbix
```

4. Adresse einfügen, Namen und Standzeit angeben — fertig

Das Skript erledigt dabei drei Dinge, an denen es sonst scheitert:

| Falle | Was das Skript tut |
|---|---|
| Direkte Adresse wird vom Browser blockiert (`X-Frame-Options`) | Schreibt den Pfad über den eigenen Proxy `/zabbix/…` |
| Zabbix-Menü steht mit auf der Wand | Hängt `&kiosk=1` an |
| Dashboard verlangt Anmeldung | Prüft es und sagt dir, was in Zabbix zu tun ist |

**Der eine Schritt, den nur du machen kannst:** Damit die Wand das Dashboard
ohne Anmeldung sieht, muss es in Zabbix freigegeben sein —
*Dashboards → dein Dashboard → Sharing → Public*. Das Skript sagt dir, wenn
das noch fehlt.

---

## Aufgabe 2 — Eine Weboberfläche einbinden

Grafana, PRTG, CheckMK, vCenter, ein Wiki:

```bash
./scripts/add.sh website
```

Gefragt werden: **Basisadresse** (`https://prtg.firma.local` — nicht die lange
URL aus der Adresszeile) und ein **Kurzname** für den Pfad.

> Immer den **vollen Namen** verwenden: `prtg.firma.local`, nicht `prtg`.
> Kurznamen lösen im Container nicht auf — das Skript warnt dich.

---

## Aufgabe 3 — Eine Sicherheitsquelle hinzufügen

```bash
./scripts/add.sh feed
```

Das Skript **prüft die Feed-Adresse sofort** und lehnt sie ab, wenn keine
Meldungen zurückkommen. Danach fragt es, wo sie erscheinen soll:

- **Nachrichtenwand** `/news/` — eigene Spalte
- **Anbieterstatus** `/stoerungen/` — eigene Karte
- beides

Adressen findest du beim Hersteller unter „RSS" oder „Security Advisories".
Kandidaten durchprobieren:

```bash
./scripts/check-feeds.sh --kandidaten
```

---

## Aufgabe 4 — Etwas von der Wand entfernen

```bash
./scripts/add.sh liste          # zeigt alles mit Nummern
nano config/pages.txt           # Zeile löschen oder # davorsetzen
docker compose restart nginx
```

---

## Aufgabe 5 — Reihenfolge und Standzeiten ändern

Alles steht in **einer** Datei:

```bash
nano config/pages.txt
docker compose restart nginx
```

```
# Name | Adresse | Sekunden
Betriebslage | /lage/       | 60
Nachrichten  | /news/       | 40
Zabbix Netz  | /zabbix/zabbix.php?action=dashboard.view&dashboardid=420&kiosk=1 | 60
```

Die Reihenfolge der Zeilen ist die Reihenfolge auf der Wand. Sekunden
weglassen = 30 s.

---

## Wenn etwas nicht angezeigt wird

**Immer zuerst:**

```bash
./scripts/check-wall.sh
```

Es ruft **jede** Seite einzeln auf und sagt, welche fehlt. In der Rotation
huscht eine kaputte Seite nach 30 Sekunden vorbei — deshalb sieht man ihr den
Fehler nie an.

| Meldung | Bedeutung | Lösung |
|---|---|---|
| `404` | Adresse gibt es nicht | Tippfehler in `config/pages.txt` |
| `500` / `502` | Pi erreicht das Ziel nicht | `./scripts/check-zabbix.sh` |
| `Zabbix verlangt Anmeldung` | Freigabe fehlt | *Sharing → Public* in Zabbix |
| `config/pages.txt fehlt` | Seitenliste nicht angelegt | `cp config/pages.txt.example config/pages.txt` |

Weitere Prüfungen:

```bash
./scripts/check-zabbix.sh     # Zabbix-Anbindung Schicht für Schicht
./scripts/check-feeds.sh      # alle Nachrichtenquellen
```

---

## Was die Wand von sich aus tut

- **Alle 30–60 s weiterschalten** — je Seite einstellbar
- **Bei einem kritischen Ausfall die Rotation abbrechen**, rot pulsieren und
  auf der Lageseite bleiben, bis Entwarnung ist
- **Alle 5 Minuten neu laden**, damit nichts einfriert
- **Sich alle 10 Minuten um wenige Pixel verschieben** (Einbrennschutz)
- **Alle 30 Minuten** nach neuen Schwachstellen suchen, die eure Produkte
  betreffen, und sie gebündelt melden

Nichts davon muss jemand bedienen.

---

## Adressen im Überblick

| Seite | Adresse |
|---|---|
| Die Wand (Rotation) | `https://<pi>/signage/` |
| Betriebslage | `https://<pi>/lage/` |
| Sicherheitsnachrichten | `https://<pi>/news/` |
| Anbieterstatus | `https://<pi>/stoerungen/` |
| Alert-Wand | `https://<pi>/wall/` |
| Grafana | `https://<pi>/grafana/` |

---

## Nach einem Update

```bash
./scripts/update.sh
```

Holt den neuen Stand, rendert die Konfiguration, baut die Grafana-Dashboards
und erzeugt die Container neu. **Ein `git pull` allein genügt nicht** — die
Container würden weiter den alten Stand sehen.

Alles unter `config/` bleibt dabei unangetastet. Deine Seiten, Quellen und
Zugangsdaten überleben jedes Update.

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
  5) Eigene Wandseite für eine Zabbix-Hostgruppe (empfohlen)
  6) Beliebige Anwendung mit REST-Schnittstelle (LOGINventory, Jira ...)
  7) Nur anzeigen, was schon drin ist
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

## Aufgabe 1b — Eine eigene Wandseite für eine Zabbix-Hostgruppe *(der beste Weg)*

Statt ein Zabbix-Dashboard einzubetten, lässt sich eine **komplette Wandseite
für eine Hostgruppe erzeugen** — mit Verfügbarkeit, offenen Problemen, CPU,
Arbeitsspeicher, Speicherplatz und Antwortzeit. Kein Klicken in Zabbix, kein
Klicken in Grafana.

```bash
./scripts/add.sh gruppe
```

Gefragt wird nur nach dem **Namen der Hostgruppe** (genau wie in Zabbix unter
*Data collection → Host groups*). Das Skript prüft die Gruppe **gegen euer
Zabbix, bevor** es etwas anlegt — und zeigt die vorhandenen Gruppen an, wenn
der Name nicht passt.

Warum das der bessere Weg ist:

| | Zabbix-Dashboard einbetten | Eigene Seite je Gruppe |
|---|---|---|
| Anmeldung nötig | ja (guest-Freigabe) | **nein** |
| Lesbar aus 5 m | wie in Zabbix gebaut | **für die Wand entworfen** |
| Neue Gruppe ergänzen | in Zabbix bauen, freigeben, einbetten | **ein Befehl** |
| Überlebt ein Update | ja | ja (`config/gruppen.txt`) |

Alle Seiten haben **denselben Zuschnitt**: Wer zwischen „Rechenzentrum" und
„Netzwerk" wechselt, muss nicht umdenken — dieselbe Zahl steht an derselben
Stelle.

Entfernen: Zeile aus `config/gruppen.txt` löschen, `./scripts/update.sh` —
die Seite verschwindet auch aus Grafana.

## Bei vielen Hostgruppen: die Übersichtsseite

Habt ihr zwanzig Hostgruppen und legt je eine Wandseite an, seht ihr jede erst
nach einer Viertelstunde wieder. Das ist kein Lagebild mehr.

Sobald **mehr als eine** Zeile in `config/gruppen.txt` steht, entsteht darum
zusätzlich automatisch eine Seite, die **alle Gruppen nebeneinander** zeigt:
je eine Kachel mit der Zahl der offenen Probleme, grün wenn nichts ansteht,
darunter die Problemliste über alle Gruppen hinweg.

```
Alle Gruppen | /grafana/d/noc-gruppen/?kiosk&refresh=30s | 60
```

**Das ist die Zeile, die auf die Wand gehört.** Eigene Seiten dann nur noch für
die drei bis fünf Gruppen, in die ihr wirklich täglich seht — nicht für alle.
Die übrigen Dashboards bleiben trotzdem erreichbar, sie laufen nur nicht mit:

```
https://<pi>/grafana/d/noc-<name>/?kiosk
```

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

## Aufgabe 3b — Eine eigene Anwendung anbinden *(LOGINventory, Jira, alles mit REST)*

```bash
./scripts/add.sh anwendung
```

Das ist der Weg für **alles, wofür es keinen eigenen Punkt im Menü gibt**.
Voraussetzung ist nur eine Adresse, die JSON zurückgibt — das können
LOGINventory, Jira, ein Ticketsystem, eine Telefonanlage oder die
Gebäudeleittechnik. Es wird **kein Code geschrieben**; die Anbindung steht in
`config/connect.ini`, und daraus wird eine Kachel auf `/kennzahlen/`.

Das Skript fragt der Reihe nach:

| Frage | Beispiel | Wofür |
|---|---|---|
| Kurzname | `jira-offen` | Abschnittsname in der ini |
| Adresse | `https://jira.firma.de/rest/api/2/search?jql=resolution=Unresolved&maxResults=0` | die JSON-Quelle |
| Anmeldung | Token / Benutzer+Passwort / eigene Kopfzeile / keine | siehe unten |
| Zahl oder Liste | eine Zahl | Kennzahl oder die neuesten Einträge |
| Pfad zum Wert | `total` | wo die Zahl in der Antwort steht |
| Gruppe, Überschrift, Einheit | `Tickets`, `Offene Tickets` | Anzeige |
| Warnung / Kritisch ab | `40` / `60` | Farbe und Symbol der Kachel |

### Der Pfad zum Wert — die einzige Stelle, an der man nachsehen muss

Öffne die Adresse einmal im Browser und sieh in die Antwort. Der Pfad ist
Punktschreibweise:

| Antwort | Pfad | Ergebnis |
|---|---|---|
| `{"total": 47}` | `total` | 47 |
| `{"@odata.count": 1284}` | `@odata.count` | 1284 *(LOGINventory/OData)* |
| `{"issues":[…, …, …]}` | `len:issues` | 3 |
| `{"issues":[{"fields":{"summary":"…"}}]}` | `issues[0].fields.summary` | der Text |

**Stimmt der Pfad nicht, bricht das Skript sofort ab** und zeigt die Schlüssel,
die wirklich in der Antwort stehen:

```
FEHLER  jira-offen: Pfad 'gibts.nicht' kommt in der Antwort nicht vor.
        Vorhanden ist: total, issues
```

Ein falscher Pfad landet also nie stillschweigend als leere Kachel auf der Wand.

### Zugangsdaten

In `config/connect.ini` steht **nie ein Passwort**, sondern nur der *Name* einer
Variablen aus `config/secrets.env`:

```ini
[jira-offen]
auth = bearer:JIRA_TOKEN      ← der Name, nicht der Token
```

Das Skript fragt den Wert ab (die Eingabe bleibt unsichtbar) und legt ihn
selbst in `config/secrets.env` ab. So kann die `connect.ini` bedenkenlos
herumgereicht oder in ein Ticket kopiert werden.

Vier Formen sind möglich:

| Form | Für |
|---|---|
| `bearer:JIRA_TOKEN` | Jira Cloud, die meisten REST-APIs |
| `basic:LOGINV_USER:LOGINV_PASS` | LOGINventory, ältere Systeme |
| `header:X-Api-Key:LOGINV_KEY` | eigener Kopfzeilenname |
| `query:apikey:LOGINV_KEY` | Schlüssel als Parameter in der Adresse |

### Später etwas ändern

```bash
nano config/connect.ini
docker compose exec connect python /app/connect.py --test jira-offen
docker compose restart connect
```

`--test` ohne Namen prüft **alle** Anbindungen auf einmal.

---

## Aufgabe 4 — Etwas von der Wand entfernen

```bash
./scripts/aufraeumen.sh            # was gehört hier nicht mehr hin?
./scripts/aufraeumen.sh --anwenden # stilllegen (löscht nichts, sichert vorher)
```

Findet Beispielwerte, tote Seiten, doppelte Zeilen und Hostgruppen, die es in
Zabbix nicht gibt. Von Hand geht es weiterhin so:

```bash
./scripts/add.sh liste          # zeigt alles mit Nummern
nano config/pages.txt           # Zeile löschen oder # davorsetzen
docker compose restart nginx
```

---

## Wie oft schaltet die Wand um?

**Je Seite einstellbar** — die dritte Spalte in `config/pages.txt` ist die
Standzeit in Sekunden. Ohne Angabe sind es 30 s.

```
Betriebslage | /lage/  | 60     ← eine Minute
Nachrichten  | /news/  | 40
Störungen    | /stoerungen/     ← 30 s (Vorgabe)
```

Ein voller Umlauf dauert so lang wie die Summe aller Zeilen. Acht Seiten à
45 s sind sechs Minuten — wer im Flur vorbeigeht, sieht also nicht alles.
Deshalb: **das Wichtigste nach oben und länger.**

## Wo trage ich die IP-Adressen ein?

In `config/probes.txt` — das ist die Liste dessen, was überwacht wird
(nicht zu verwechseln mit `pages.txt`, das ist die Anzeige).

```bash
nano config/probes.txt
docker compose restart probe
```

```
# Name          | Gruppe    | Ziel
Firewall        | Netzwerk  | https://10.30.10.1
DC01 LDAP       | Identity  | tcp://10.30.191.20:389
Interner DNS    | Netzwerk  | dns://intranet.firma.local
Internet        | Netzwerk  | https://www.msftconnecttest.com/connecttest.txt
```

IP-Adressen funktionieren **direkt** und sind hier sogar die sichere Wahl —
bei Namen muss der volle Name (FQDN) stehen, Kurznamen lösen im Container
nicht auf.

| Ziel | Was geprüft wird |
|---|---|
| `https://10.30.10.1` | Erreichbarkeit, Antwortzeit, **Zertifikatsrestlaufzeit** |
| `tcp://10.30.191.20:389` | Port offen, Verbindungszeit |
| `dns://name.firma.local` | Löst der Name auf |

Sofort prüfen, ob die Ziele stimmen:

```bash
docker compose exec probe python /app/probe.py --once
```

> **Alle Beispielzeilen sind auskommentiert** — mit Absicht. `example.local`
> löst nirgends auf; wären die Zeilen aktiv, stünde die Wand ab der ersten
> Minute auf Dauer-Alarm.

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
./scripts/status.sh      # Gesamtbild: Container, Seiten, Daten, Sicherheit
./scripts/check-wall.sh  # jede einzelne Seite aus config/pages.txt
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
./scripts/check-grafana.sh    # Grafana auf diesem Pi
```

---

## Was die Wand von sich aus tut

- **Alle 30–60 s weiterschalten** — je Seite einstellbar
- **Bei einem kritischen Ausfall die Rotation abbrechen**, rot pulsieren und
  auf der Lageseite bleiben, bis Entwarnung ist — höchstens aber 15 Minuten,
  danach läuft die Rotation weiter und nur die Warnung bleibt stehen
- **Keinen Alarm auslösen, wenn *alles* kritisch ist.** Dann ist fast nie alles
  kaputt, sondern die Konfiguration stimmt nicht — die Wand sagt das und
  rotiert weiter, statt sich festzufahren
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
| Wochenrückblick | `https://<pi>/woche/` |
| Kennzahlen (angebundene Anwendungen) | `https://<pi>/kennzahlen/` |
| Grafana | `https://<pi>/grafana/` |
| Eigene Gruppenseite | `https://<pi>/grafana/d/noc-<name>/?kiosk` |
| Anbieterstatus | `https://<pi>/stoerungen/` |
| Alert-Wand | `https://<pi>/wall/` |

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

# Sicherheit

Diese Wand hängt im Flur und ist mit euren Systemen verbunden. Beides zusammen
macht sie interessant — für Besucher wie für Angreifer. Dieses Dokument sagt,
was geschützt ist, was **ihr** entscheiden müsst, und was ausdrücklich **nicht**
abgedeckt ist.

Prüfen lässt sich der Stand jederzeit:

```bash
./scripts/status.sh
```

---

## Das Grundprinzip: die Wand hält keine Geheimnisse

Ein Bildschirm im Flur ist physisch nicht geschützt. Jeder kann ihn abfotografieren,
und an vielen Geräten kommt man mit ein paar Tastendrücken an eine Adresszeile.
Deshalb gilt durchgehend:

> **Kein Zugangsdatum erreicht jemals den Browser.**

| Zugangsdatum | Wo es liegt | Wie es zur Anwendung kommt |
|---|---|---|
| Zabbix-API-Token | `config/secrets.env` (chmod 600) | Nginx hängt ihn **serverseitig** an |
| Grafana-Admin-Passwort | `.env` | nur für `/grafana/` im Browser eines Menschen |
| CVE-Webhook-URL | `config/secrets.env` | nur im Container des Watchers |
| NVD-API-Key | `config/secrets.env` | dito |

Im Quelltext der Wandseiten steht **kein einziges** davon. Wer `Strg+U` drückt,
sieht Fetch-Aufrufe auf `/api/zabbix` und `/feeds/…` — eigene Adressen ohne
Anmeldedaten.

---

## Was der Pi nach außen anbietet

| Port | Dienst | Zugriff |
|---|---|---|
| 80 | Nginx | leitet **ausschließlich** auf 443 um |
| 443 | Nginx (TLS) | die Wandseiten, `/grafana/`, die Proxys |

Alles andere — Dashy, Grafana, die Sonde, der CVE-Watcher — läuft in einem
internen Docker-Netz und ist **von außen nicht erreichbar** (`expose` statt
`ports`). Es gibt keinen offenen Datenbank- oder Grafana-Port.

Geprüft mit `./scripts/status.sh`: HTTP muss umlenken, `/admin` muss 401 liefern.

---

## Der wichtigste Baustein: der Zabbix-Proxy liest nur

`/api/zabbix` hängt den API-Token serverseitig an. Ohne weitere Maßnahme wäre
das ein **offenes Tor**: Wer den Pi im Netz erreicht, könnte darüber jede
Zabbix-Methode aufrufen — auch `host.delete`, `user.create` oder
`script.execute`, mit den Rechten des Tokens.

Deshalb lässt Nginx nur lesende Methoden durch:

```
problem.get · trigger.get · host.get · hostgroup.get · hostinterface.get
event.get · item.get · service.get · maintenance.get · apiinfo.version
```

Alles andere wird mit **403** abgewiesen, ebenso ein leerer Rumpf. Dazu ein
Ratenlimit von 30 Anfragen pro Minute und Quelle — die Wand selbst braucht drei.

`./scripts/status.sh` macht die **Gegenprobe zur Laufzeit**: Es schickt ein
`host.delete` und meldet einen Fehler, falls das *nicht* abgewiesen wird.

---

## Was ihr entscheiden müsst

Diese Punkte kann euch niemand abnehmen — sie hängen an eurer Umgebung.

### 1. Der Zabbix-Token braucht eine Nur-Lese-Rolle

**Das ist die wichtigste Einzelentscheidung.** Der Methodenfilter ist die zweite
Verteidigungslinie; die erste ist ein Token, der gar nichts anderes darf.

In Zabbix:
- *Users → Users*: eigenen Benutzer `wand-anzeige` anlegen, **nicht** einen
  bestehenden Admin verwenden
- *Users → User roles*: Rolle mit `User type: User`, **API: Enabled**,
  *API methods* auf **Deny list** mit `*.create`, `*.update`, `*.delete`,
  `*.massupdate`, `script.*` — oder Allow-List mit genau den zehn Methoden oben
- *Permissions*: nur **Read** auf die Hostgruppen, die auf die Wand sollen

Ein Token mit Admin-Rechten wäre auch mit Filter ein unnötiges Risiko.

### 2. In welchem Netz steht der Pi?

Die Wand zeigt interne Hostnamen, IP-Adressen und Störungen. Das ist kein
Geheimnis ersten Ranges, aber eine Landkarte eurer Umgebung.

**Empfehlung:** eigenes VLAN oder Management-Netz, erreichbar nur aus dem
Client-Netz — nicht aus Gastnetz oder WLAN für Besucher. Ausgehend braucht der
Pi: Zabbix, die überwachten Systeme, `api.nvd.nist.gov`, `www.cisa.gov`, die
Feed-Anbieter und die Webhook-URL.

### 3. Wer darf auf `/grafana/` administrieren?

Die Wand liest **anonym und nur lesend** (`Viewer`). Zum Bauen von Dashboards
gibt es den `admin`-Zugang mit `GRAFANA_ADMIN_PASSWORD` aus `.env`.

- Passwort **ändern** — `status.sh` meldet das Standardpasswort als Fehler
- Soll sich niemand anmelden können: `GRAFANA_HIDE_LOGIN=true` in `.env`

### 4. Das TLS-Zertifikat

Ausgeliefert wird ein selbstsigniertes. Für eine Wand im eigenen Netz ist das
vertretbar, erzeugt aber bei jedem Aufruf eine Warnung. Besser: ein Zertifikat
eurer internen PKI (Anleitung in der README). `status.sh` warnt 30 Tage vor
Ablauf.

### 5. Bevor ihr Microsoft 365 „richtig" anbindet

Es gibt **keinen öffentlichen Service-Health-Feed** mehr. Echte Tenant-Störungen
liefert nur die Graph-API — und die braucht eine App-Registrierung mit
Client-Secret.

Wenn ihr das wollt, ist das eine bewusste Entscheidung:
- Berechtigung **`ServiceHealth.Read.All`** (Application), sonst nichts
- Secret mit Ablaufdatum, in `config/secrets.env`
- Der Abruf läuft im Container, nie im Browser

**Sag Bescheid, wenn ihr das anbinden wollt** — dann baue ich es mit genau
dieser einen Berechtigung. Ohne App-Registrierung bleibt es beim öffentlichen
Änderungs-Feed, und die Karte heißt ehrlich „M365 Änderungen".

---

## Was dieses System bewusst NICHT tut

Ehrlichkeit ist hier wichtiger als eine lange Featureliste:

- **Es ersetzt kein SIEM und kein Alarmierungssystem.** Die Wand zeigt; sie
  eskaliert nicht, quittiert nicht und führt kein Protokoll, das vor einem
  Auditor Bestand hätte.
- **Es prüft nicht, ob ihr verwundbar seid.** Der CVE-Watcher meldet, dass ein
  Advisory *eines eurer Produkte* betrifft. Ob eure Version betroffen ist, steht
  im Advisory — der Titel ist deshalb klickbar.
- **Es authentifiziert keine Betrachter.** Wer den Pi im Netz erreicht, sieht die
  Wandseiten. Das ist Absicht (eine Wand hat keine Anmeldung) und der Grund für
  Punkt 2 oben.
- **Der Screenshot-Dienst ist ein Browser.** `shotter` rendert fremde Seiten mit
  Chromium. Er ist standardmäßig **ohne Ziele** konfiguriert. Setzt dort nur
  Adressen ein, denen ihr vertraut.

---

## Checkliste vor dem Produktivgang

```bash
./scripts/status.sh          # muss grün sein
```

- [ ] Zabbix-Token gehört einem **eigenen Nur-Lese-Benutzer**
- [ ] `chmod 600 config/secrets.env`
- [ ] `GRAFANA_ADMIN_PASSWORD` geändert
- [ ] Pi steht in einem Netz, das nicht jeder erreicht
- [ ] Internes Zertifikat eingespielt (oder bewusst dagegen entschieden)
- [ ] `./scripts/backup.sh` läuft nachts, und eine Sicherung wurde **einmal
      zurückgespielt** — eine ungeprüfte Sicherung ist keine
- [ ] `git status` zeigt keine Zugangsdaten als Änderung

---

## Wenn ein Token kompromittiert wurde

1. In Zabbix: *Users → API tokens* → betroffenen Token **löschen**, neuen anlegen
2. Neuen Token in `config/secrets.env` eintragen
3. `./scripts/update.sh`
4. In Zabbix prüfen, ob der alte Token benutzt wurde: *Reports → Audit log*,
   gefiltert auf den Benutzer

Dasselbe für die Webhook-URL: In der Logic App den Trigger neu erzeugen — die
Signatur in der URL ist das Geheimnis.

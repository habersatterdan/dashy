#!/usr/bin/env python3
"""
Erzeugt die Grafana-Dashboards als JSON-Dateien.

WARUM ALS GENERATOR statt handgeklickter Dashboards:
Ein im Browser zusammengeklicktes Dashboard lebt in Grafanas Datenbank - es
ist nicht versioniert, nicht reproduzierbar und beim naechsten Neuaufbau des
Pi weg. Hier steht das Layout als Code: nachvollziehbar, wiederholbar, und
Aenderungen sind ein Diff.

    ./scripts/build-dashboards.py          # schreibt grafana/dashboards/*.json

Die Panels benutzen zwei Datenquellen:
  zabbix  - euer Zabbix (Plugin alexanderzobnin-zabbix-datasource)
  sonde   - unsere eigene Messung und der CVE-Watcher (Infinity-Plugin)

ANPASSEN: Die Item-Namen ("CPU utilization", "Memory utilization" ...) sind
die Vorgaben der offiziellen Zabbix-Templates. Weichen eure ab, hier zentral
aendern statt in 20 Panels.
"""
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "grafana" / "dashboards"

ZBX = {"type": "alexanderzobnin-zabbix-datasource", "uid": "zabbix"}
INF = {"type": "yesoreyeram-infinity-datasource", "uid": "sonde"}

# Item-Namen der Zabbix-Standardtemplates - hier zentral anpassbar.
I_CPU   = "/CPU utilization/"
I_MEM   = "/Memory utilization/"
I_FS    = "/Space utilization/"
I_PING  = "/ICMP response time/"
I_LOSS  = "/ICMP loss/"
I_NET_I = "/Bits received/"
I_NET_O = "/Bits sent/"
I_UP    = "/ICMP ping$/"

# Validierte Statusfarben: Farbe traegt nie allein Bedeutung, jedes Panel
# fuehrt zusaetzlich Titel und Einheit.
GOOD, WARN, SERIOUS, CRIT = "#0ca30c", "#fab219", "#ec835a", "#d03b3b"


def schwellen(*paare, base="text"):
    """thresholds-Block: (wert, farbe) ... ; None = Basiswert."""
    steps = [{"color": base, "value": None}]
    steps += [{"color": c, "value": v} for v, c in paare]
    return {"mode": "absolute", "steps": steps}


def panel(typ, titel, x, y, w, h, targets, *, unit="short", opts=None,
          thresholds=None, ds=ZBX, desc="", mappings=None, maxv=None,
          minv=None, dezimal=None):
    p = {
        "type": typ, "title": titel, "id": None,
        "gridPos": {"x": x, "y": y, "w": w, "h": h},
        "datasource": ds, "targets": targets,
        "description": desc,
        "fieldConfig": {
            "defaults": {
                "unit": unit,
                "color": {"mode": "thresholds" if thresholds else "palette-classic"},
                "custom": {},
            },
            "overrides": [],
        },
        "options": opts or {},
    }
    d = p["fieldConfig"]["defaults"]
    if thresholds:
        d["thresholds"] = thresholds
    if mappings:
        d["mappings"] = mappings
    if maxv is not None:
        d["max"] = maxv
    if minv is not None:
        d["min"] = minv
    if dezimal is not None:
        d["decimals"] = dezimal
    return p


def zbx_metrik(gruppe, host, item, funcs=None):
    return [{
        "datasource": ZBX, "queryType": "0", "refId": "A",
        "group": {"filter": gruppe}, "host": {"filter": host},
        "application": {"filter": ""}, "itemTag": {"filter": ""},
        "item": {"filter": item},
        "functions": funcs or [],
        "options": {"showDisabledItems": False, "skipEmptyValues": False,
                    "disableDataAlignment": False, "useZabbixValueMapping": True},
    }]


def zbx_probleme(gruppe="/.*/", schwere=None, limit=100):
    """Problems-Abfrage. severities: 0 nicht klassifiziert ... 5 Katastrophe."""
    return [{
        "datasource": ZBX, "queryType": "5", "refId": "A",
        "group": {"filter": gruppe}, "host": {"filter": "/.*/"},
        "application": {"filter": ""}, "proxy": {"filter": ""},
        "trigger": {"filter": ""},
        "options": {
            "minSeverity": 0, "sortProblems": "severity",
            "acknowledged": 2, "hostsInMaintenance": False,
            "hostProxy": False, "limit": limit,
            "severities": schwere if schwere is not None else [0, 1, 2, 3, 4, 5],
        },
    }]


def sonde_query(url, wurzel, spalten, refid="A"):
    """Infinity-Abfrage auf unser eigenes JSON."""
    return [{
        "datasource": INF, "refId": refid, "type": "json", "source": "url",
        "format": "table", "url": url, "url_options": {"method": "GET"},
        "root_selector": wurzel,
        "columns": [{"selector": s, "text": t, "type": ty}
                    for s, t, ty in spalten],
    }]


def text_panel(titel, x, y, w, h, inhalt):
    return {"type": "text", "title": titel, "gridPos": {"x": x, "y": y, "w": w, "h": h},
            "options": {"mode": "markdown", "content": inhalt}}


def dashboard(uid, titel, panels, refresh="30s", zeit="now-6h"):
    for i, p in enumerate(panels, 1):
        p["id"] = i
    return {
        "uid": uid, "title": titel, "tags": ["noc", "wall"],
        "timezone": "browser", "schemaVersion": 39, "version": 1,
        "refresh": refresh,
        "time": {"from": zeit, "to": "now"},
        "timepicker": {"hidden": True},
        # Auf einer Wand gibt es keine Bedienung - alles Interaktive weg.
        "editable": True, "graphTooltip": 0,
        "style": "dark", "panels": panels,
        "templating": {"list": []}, "annotations": {"list": []},
    }


# =============================================================================
# 1. LAGEBILD - die Seite, die am laengsten steht
# =============================================================================
def dash_lagebild():
    p = []
    # --- Kopfzeile: vier Hero-Zahlen, aus fuenf Metern lesbar --------------
    p.append(panel("stat", "Hosts erreichbar", 0, 0, 6, 5,
        zbx_metrik("/.*/", "/.*/", I_UP, [{"def": {"name": "percentil"}, "params": []}]),
        unit="percent", dezimal=1,
        thresholds=schwellen((0, CRIT), (95, WARN), (99.5, GOOD)),
        opts={"graphMode": "none", "colorMode": "value", "textMode": "auto",
              "reduceOptions": {"calcs": ["lastNotNull"], "fields": "", "values": False}},
        desc="Anteil der Hosts, die auf ICMP antworten. Die eine Zahl, die "
             "beim Vorbeilaufen zaehlt."))

    p.append(panel("stat", "Aktive Ausfaelle", 6, 0, 6, 5,
        zbx_probleme(schwere=[4, 5]), unit="none",
        thresholds=schwellen((1, CRIT), base=GOOD),
        opts={"graphMode": "none", "colorMode": "background", "textMode": "value",
              "reduceOptions": {"calcs": ["count"], "fields": "", "values": False}},
        desc="Probleme der Stufen Hoch und Katastrophe. Ab 1 faerbt sich die "
             "Flaeche - das sieht man auch aus dem Augenwinkel."))

    p.append(panel("stat", "Warnungen", 12, 0, 6, 5,
        zbx_probleme(schwere=[2, 3]), unit="none",
        thresholds=schwellen((1, WARN), base=GOOD),
        opts={"graphMode": "none", "colorMode": "value", "textMode": "value",
              "reduceOptions": {"calcs": ["count"], "fields": "", "values": False}}))

    p.append(panel("stat", "Neu in 24 h", 18, 0, 6, 5,
        zbx_probleme(), unit="none",
        thresholds=schwellen((5, WARN), (15, SERIOUS), base=GOOD),
        opts={"graphMode": "area", "colorMode": "value", "textMode": "value",
              "reduceOptions": {"calcs": ["count"], "fields": "", "values": False}},
        desc="Zuwachs statt Bestand: sagt, ob gerade etwas passiert."))

    # --- Die Problemliste: das Herzstueck ----------------------------------
    p.append(panel("table", "Offene Probleme", 0, 5, 14, 11,
        zbx_probleme(limit=14),
        opts={"showHeader": True, "footer": {"show": False},
              "cellHeight": "lg", "sortBy": [{"displayName": "Severity", "desc": True}]},
        desc="Nach Schweregrad sortiert. Mehr als 14 Zeilen passen aus der "
             "Entfernung ohnehin nicht auf den Schirm."))

    # --- Verfuegbarkeit als Zeitband: Muster statt Momentaufnahme ----------
    p.append(panel("state-timeline", "Verfuegbarkeit Kernsysteme (24 h)", 14, 5, 10, 11,
        zbx_metrik("/Kernsysteme|Core|Server/", "/.*/", I_UP),
        unit="none", thresholds=schwellen((1, GOOD), base=CRIT),
        mappings=[{"type": "value", "options": {"0": {"text": "aus", "color": CRIT},
                                                "1": {"text": "laeuft", "color": GOOD}}}],
        opts={"mergeValues": True, "showValue": "never", "rowHeight": 0.9,
              "legend": {"showLegend": False}, "alignValue": "center"},
        desc="Ein Balken je Host ueber 24 Stunden. Kurze Aussetzer, die eine "
             "Momentanzeige nie zeigt, werden hier als Luecke sichtbar."))

    # --- Auslastung: wo wird es eng ----------------------------------------
    p.append(panel("bargauge", "CPU - hoechste Auslastung", 0, 16, 8, 8,
        zbx_metrik("/.*/", "/.*/", I_CPU, [{"def": {"name": "top"}, "params": ["8", "avg"]}]),
        unit="percent", maxv=100, minv=0,
        thresholds=schwellen((70, WARN), (85, SERIOUS), (95, CRIT), base=GOOD),
        opts={"displayMode": "gradient", "orientation": "horizontal",
              "showUnfilled": True, "valueMode": "color",
              "reduceOptions": {"calcs": ["lastNotNull"], "fields": "", "values": False}}))

    p.append(panel("bargauge", "Arbeitsspeicher - hoechste Auslastung", 8, 16, 8, 8,
        zbx_metrik("/.*/", "/.*/", I_MEM, [{"def": {"name": "top"}, "params": ["8", "avg"]}]),
        unit="percent", maxv=100, minv=0,
        thresholds=schwellen((80, WARN), (90, SERIOUS), (96, CRIT), base=GOOD),
        opts={"displayMode": "gradient", "orientation": "horizontal",
              "showUnfilled": True, "valueMode": "color",
              "reduceOptions": {"calcs": ["lastNotNull"], "fields": "", "values": False}}))

    p.append(panel("bargauge", "Speicherplatz - vollste Volumes", 16, 16, 8, 8,
        zbx_metrik("/.*/", "/.*/", I_FS, [{"def": {"name": "top"}, "params": ["8", "avg"]}]),
        unit="percent", maxv=100, minv=0,
        thresholds=schwellen((80, WARN), (90, SERIOUS), (95, CRIT), base=GOOD),
        opts={"displayMode": "gradient", "orientation": "horizontal",
              "showUnfilled": True, "valueMode": "color",
              "reduceOptions": {"calcs": ["lastNotNull"], "fields": "", "values": False}},
        desc="Der haeufigste vermeidbare Ausfall. Faellt hier etwas ueber 90 %, "
             "hat man noch Tage Zeit - wenn jemand hinschaut."))
    return dashboard("noc-lagebild", "NOC · Lagebild", p, refresh="30s", zeit="now-24h")


# =============================================================================
# 2. INFRASTRUKTUR & RECHENZENTRUM
# =============================================================================
def dash_infra():
    p = []
    p.append(panel("timeseries", "WAN-Durchsatz", 0, 0, 12, 8,
        zbx_metrik("/Netzwerk|Network|Firewall/", "/.*/", I_NET_I,
                   [{"def": {"name": "top"}, "params": ["4", "avg"]}]),
        unit="bps",
        opts={"legend": {"displayMode": "list", "placement": "bottom", "showLegend": True},
              "tooltip": {"mode": "multi"}},
        desc="Der Puls der Firma. Ein Einbruch mitten am Tag faellt sofort auf, "
             "ein Dauerausschlag nachts ebenso - beides Gespraechsanlaesse."))

    p.append(panel("timeseries", "Antwortzeit Kernsysteme", 12, 0, 12, 8,
        zbx_metrik("/.*/", "/.*/", I_PING,
                   [{"def": {"name": "top"}, "params": ["6", "avg"]}]),
        unit="s", dezimal=3,
        opts={"legend": {"displayMode": "list", "placement": "bottom", "showLegend": True},
              "tooltip": {"mode": "multi"}},
        desc="Latenz sagt frueher Bescheid als ein Ausfall: Sie steigt, bevor "
             "etwas ganz stehenbleibt."))

    p.append(panel("piechart", "Probleme nach Hostgruppe", 0, 8, 7, 8,
        zbx_probleme(),
        opts={"legend": {"displayMode": "table", "placement": "right",
                         "values": ["value"], "showLegend": True},
              "pieType": "donut", "displayLabels": ["percent"],
              "reduceOptions": {"calcs": ["count"], "fields": "", "values": True}},
        desc="Zeigt, ob sich Probleme haeufen - ein Cluster in einer Gruppe "
             "ist fast immer eine gemeinsame Ursache."))

    p.append(panel("table", "Zertifikate - Restlaufzeit", 7, 8, 9, 8,
        sonde_query("http://nginx/data/probe.json", "targets",
                    [("name", "Dienst", "string"),
                     ("group", "Gruppe", "string"),
                     ("cert_days", "Tage", "number"),
                     ("message", "Status", "string")]),
        ds=INF, unit="d",
        thresholds=schwellen((0, CRIT), (7, SERIOUS), (30, WARN), base=GOOD),
        opts={"showHeader": True, "cellHeight": "md",
              "sortBy": [{"displayName": "Tage", "desc": False}]},
        desc="Aus unserer eigenen Sonde. Der Klassiker, der sonst erst am "
             "Ausfalltag auffaellt - hier Wochen vorher."))

    p.append(panel("stat", "Dienste erreichbar (Sonde)", 16, 8, 8, 8,
        sonde_query("http://nginx/data/probe.json", "summary",
                    [("ok", "OK", "number"), ("warn", "Warnung", "number"),
                     ("crit", "Gestoert", "number")]),
        ds=INF, unit="none",
        thresholds=schwellen((1, WARN), base=GOOD),
        opts={"graphMode": "none", "colorMode": "value", "textMode": "value_and_name",
              "orientation": "horizontal",
              "reduceOptions": {"calcs": ["lastNotNull"], "fields": "", "values": False}},
        desc="Zweite Meinung: von der Wand aus gemessen, unabhaengig davon, ob "
             "Zabbix gerade selbst gesund ist."))

    p.append(panel("bargauge", "Datastores / Speicher-Pools", 0, 16, 12, 8,
        zbx_metrik("/VMware|vCenter|Storage|Datastore/", "/.*/", I_FS,
                   [{"def": {"name": "top"}, "params": ["6", "avg"]}]),
        unit="percent", maxv=100, minv=0,
        thresholds=schwellen((75, WARN), (85, SERIOUS), (92, CRIT), base=GOOD),
        opts={"displayMode": "lcd", "orientation": "horizontal",
              "showUnfilled": True, "valueMode": "color",
              "reduceOptions": {"calcs": ["lastNotNull"], "fields": "", "values": False}},
        desc="Ein volles Datastore legt alle VMs darauf still. Deshalb frueher "
             "Alarm als bei normalen Volumes."))

    p.append(panel("timeseries", "Speicherplatz - Trend 30 Tage", 12, 16, 12, 8,
        zbx_metrik("/.*/", "/.*/", I_FS, [{"def": {"name": "top"}, "params": ["5", "avg"]}]),
        unit="percent", maxv=100,
        opts={"legend": {"displayMode": "list", "placement": "bottom", "showLegend": True},
              "tooltip": {"mode": "multi"}},
        desc="Die Steigung ist die Botschaft: Sie sagt, WANN es eng wird - "
             "nicht nur, dass es eng ist. Grafanas Trenddaten machen das "
             "ueber Wochen bezahlbar."))
    return dashboard("noc-infra", "NOC · Infrastruktur", p, refresh="1m", zeit="now-7d")


# =============================================================================
# 3. SECURITY & TRENDS
# =============================================================================
def dash_security():
    p = []
    p.append(panel("stat", "Externe Schwachstellen (P1)", 0, 0, 6, 5,
        sonde_query("http://nginx/data/cve.json", "summary",
                    [("p1", "P1", "number")]),
        ds=INF, unit="none",
        thresholds=schwellen((1, CRIT), base=GOOD),
        opts={"graphMode": "none", "colorMode": "background", "textMode": "value",
              "reduceOptions": {"calcs": ["lastNotNull"], "fields": "", "values": False}},
        desc="Aus dem CVE-Watcher: betrifft eure Produkte laut Watchlist."))

    p.append(panel("stat", "Aktiv ausgenutzt (KEV)", 6, 0, 6, 5,
        sonde_query("http://nginx/data/cve.json", "summary",
                    [("kev_count", "KEV", "number")]),
        ds=INF, unit="none",
        thresholds=schwellen((1, CRIT), base=GOOD),
        opts={"graphMode": "none", "colorMode": "background", "textMode": "value",
              "reduceOptions": {"calcs": ["lastNotNull"], "fields": "", "values": False}},
        desc="CISAs KEV-Liste: nachweislich ausgenutzt. Das schaerfste Signal, "
             "das es gibt - es schlaegt jeden CVSS-Wert."))

    p.append(panel("stat", "Anmeldefehler (1 h)", 12, 0, 6, 5,
        zbx_metrik("/.*/", "/.*/", "/Failed login|Anmeldefehler|failed_logins/"),
        unit="none",
        thresholds=schwellen((50, WARN), (200, SERIOUS), (500, CRIT), base=GOOD),
        opts={"graphMode": "area", "colorMode": "value", "textMode": "value",
              "reduceOptions": {"calcs": ["sum"], "fields": "", "values": False}},
        desc="Ein Ausschlag hier ist entweder ein Angriff oder ein kaputter "
             "Dienstaccount. Beides will man wissen."))

    p.append(panel("stat", "Letzter Backup-Lauf", 18, 0, 6, 5,
        zbx_metrik("/Backup|Veeam/", "/.*/", "/last backup|Backup status|letzter Lauf/"),
        unit="dtdurations",
        thresholds=schwellen((90000, WARN), (172800, CRIT), base=GOOD),
        opts={"graphMode": "none", "colorMode": "background", "textMode": "value",
              "reduceOptions": {"calcs": ["lastNotNull"], "fields": "", "values": False}},
        desc="Alter des juengsten erfolgreichen Laufs. Ueber 25 Stunden gelb, "
             "ueber 48 rot - ein Backup, das niemand prueft, ist keins."))

    p.append(panel("table", "Offene Schwachstellen mit Bezug zu uns", 0, 5, 14, 10,
        sonde_query("http://nginx/data/cve.json", "findings",
                    [("priority", "Prio", "string"),
                     ("title", "Advisory", "string"),
                     ("cvss.score", "CVSS", "number"),
                     ("cve_count", "CVEs", "number"),
                     ("published", "Veroeffentlicht", "string")]),
        ds=INF,
        opts={"showHeader": True, "cellHeight": "md",
              "sortBy": [{"displayName": "Prio", "desc": False}]},
        desc="Gruppiert nach Advisory, nicht nach CVE - ein Sammeladvisory mit "
             "sieben CVEs ist eine Aufgabe, nicht sieben."))

    p.append(panel("timeseries", "Problem-Aufkommen (7 Tage)", 14, 5, 10, 10,
        zbx_probleme(),
        unit="none",
        opts={"legend": {"showLegend": False}, "tooltip": {"mode": "single"}},
        desc="Wird es besser oder schlechter? Die Frage, die in der taeglichen "
             "Hektik untergeht - und die jeden Vorgesetzten interessiert."))

    p.append(panel("state-timeline", "Patchstand der Server", 0, 15, 12, 7,
        zbx_metrik("/Windows|Server/", "/.*/", "/pending updates|ausstehende Updates/"),
        unit="none",
        thresholds=schwellen((1, WARN), (10, SERIOUS), (25, CRIT), base=GOOD),
        opts={"mergeValues": True, "showValue": "auto", "rowHeight": 0.85,
              "legend": {"showLegend": False}},
        desc="Ausstehende Updates je Server ueber die Zeit. Zeigt nicht nur "
             "den Stand, sondern ob ueberhaupt gepatcht wird."))

    p.append(panel("timeseries", "Firewall - abgewiesene Verbindungen", 12, 15, 12, 7,
        zbx_metrik("/Firewall|Fortinet/", "/.*/", "/deny|dropped|blocked/"),
        unit="short",
        opts={"legend": {"displayMode": "list", "placement": "bottom", "showLegend": True},
              "tooltip": {"mode": "multi"}},
        desc="Der Grundpegel ist immer da. Interessant ist die Abweichung "
             "davon - deshalb als Verlauf und nicht als Zahl."))
    return dashboard("noc-security", "NOC · Security & Trends", p, refresh="1m", zeit="now-7d")


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    for name, bauen in [("lagebild", dash_lagebild), ("infra", dash_infra),
                        ("security", dash_security)]:
        d = bauen()
        ziel = OUT / f"{name}.json"
        ziel.write_text(json.dumps(d, indent=2, ensure_ascii=False) + "\n")
        print(f"  {ziel.relative_to(ROOT)}  ({len(d['panels'])} Panels)")
    print("Fertig. Grafana liest sie beim naechsten Start (oder nach 30 s) ein.")


if __name__ == "__main__":
    main()

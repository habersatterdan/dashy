#!/usr/bin/env python3
"""
Der Universalanschluss: JEDE Anwendung mit einer REST-Schnittstelle auf die
Wand bringen - ohne eine Zeile Code.

WARUM ES DAS GIBT:
Fuer Zabbix, M365 und die CVE-Quellen gibt es je einen eigenen Dienst, weil
dort wirklich Logik steckt. Fuer alles andere - LOGINventory, Jira, ein
Ticketsystem, eine Hausautomatisierung - ist es immer dasselbe: eine URL
abrufen, eine Zahl oder eine Liste herausziehen, Schwellen anlegen, anzeigen.
Das hier ist genau dieser Ablauf, gesteuert ueber config/connect.ini.

SICHERHEIT:
Zugangsdaten stehen NIE in der ini-Datei, sondern als Name einer Variablen aus
config/secrets.env. So kann die ini-Datei bedenkenlos herumgereicht werden,
und ein Blick in die Konfiguration verraet keine Geheimnisse.

    python connect.py            # Dauerbetrieb
    python connect.py --once     # ein Durchlauf
    python connect.py --test jira   # nur diesen einen pruefen, nichts schreiben
"""
import base64, configparser, json, os, re, ssl, sys, time
import urllib.error, urllib.parse, urllib.request
from datetime import datetime, timezone
from pathlib import Path

CONF_FILE = Path(os.getenv("CONNECT_CONF", "/config/connect.ini"))
OUT_FILE  = Path(os.getenv("CONNECT_OUT", "/state/connect.json"))
INTERVAL  = int(os.getenv("CONNECT_POLL_SECONDS", "300"))
TIMEOUT   = float(os.getenv("CONNECT_TIMEOUT", "20"))
CORP_CA   = os.getenv("CORP_CA_FILE", "").strip()
# Interne Anwendungen haben oft ein eigenes Zertifikat. Die Erreichbarkeit
# soll daran nicht scheitern - aber es ist eine bewusste Entscheidung.
VERIFY    = os.getenv("CONNECT_VERIFY_TLS", "true").lower() in ("1", "true", "yes")


def log(msg):
    print(f"{datetime.now(timezone.utc):%Y-%m-%dT%H:%M:%SZ}  {msg}", flush=True)


def ctx():
    c = ssl.create_default_context()
    for ca in (x.strip() for x in CORP_CA.split(":") if x.strip()):
        if Path(ca).is_file():
            try:
                c.load_verify_locations(ca)
            except Exception:
                pass
    if not VERIFY:
        c.check_hostname = False
        c.verify_mode = ssl.CERT_NONE
    return c


SSL_CTX = ctx()


# --- Zugangsdaten -----------------------------------------------------------
def kopfzeilen(auth):
    """"bearer:JIRA_TOKEN" oder "basic:LOGINV_USER:LOGINV_PASS" oder
    "header:X-Api-Key:LOGINV_KEY" - die GROSSBUCHSTABEN sind Namen von
    Variablen aus config/secrets.env, nie die Werte selbst."""
    auth = (auth or "").strip()
    if not auth:
        return {}, None
    art, _, rest = auth.partition(":")
    art = art.lower()

    def wert(name):
        v = os.getenv(name.strip(), "")
        if not v:
            raise RuntimeError(f"{name.strip()} fehlt in config/secrets.env")
        return v

    if art == "bearer":
        return {"Authorization": f"Bearer {wert(rest)}"}, None
    if art == "basic":
        benutzer, _, passwort = rest.partition(":")
        roh = f"{wert(benutzer)}:{wert(passwort)}".encode()
        return {"Authorization": "Basic " + base64.b64encode(roh).decode()}, None
    if art == "header":
        name, _, var = rest.partition(":")
        return {name.strip(): wert(var)}, None
    if art == "query":
        # z. B. "query:apikey:LOGINV_KEY" -> ...?apikey=<wert>
        name, _, var = rest.partition(":")
        return {}, (name.strip(), wert(var))
    raise RuntimeError(f"Unbekannte Auth-Art '{art}' "
                       "(bearer | basic | header | query)")


# --- Werte herausziehen -----------------------------------------------------
PFAD = re.compile(r"([^.\[\]]+)|\[(\d+)\]")


def hole(daten, pfad):
    """Punktpfad mit Feldindex:  issues[0].fields.summary
    Sonderform 'len:feld' zaehlt die Eintraege einer Liste."""
    pfad = (pfad or "").strip()
    if not pfad:
        return daten
    if pfad.startswith("len:"):
        w = hole(daten, pfad[4:])
        return len(w) if isinstance(w, (list, dict)) else None
    # Erst woertlich versuchen: OData-Antworten enthalten Schluessel MIT Punkt
    # ("@odata.count"), und LOGINventory liefert genau die. Ein blindes
    # Aufteilen am Punkt wuerde daran scheitern - und der Fehler saehe aus wie
    # ein falscher Pfad, nicht wie ein Parser-Problem.
    if isinstance(daten, dict) and pfad in daten:
        return daten[pfad]

    wert = daten
    teile = PFAD.findall(pfad)
    i = 0
    while i < len(teile):
        if wert is None:
            return None
        name, idx = teile[i]
        if idx:
            wert = wert[int(idx)] if isinstance(wert, list) and int(idx) < len(wert) else None
            i += 1
            continue
        if isinstance(wert, dict):
            if name in wert:
                wert = wert[name]
                i += 1
                continue
            # Schluessel mit Punkt: naechste Teile probeweise anhaengen.
            zusammen = name
            j = i + 1
            gefunden = False
            while j < len(teile) and teile[j][0]:
                zusammen = f"{zusammen}.{teile[j][0]}"
                j += 1
                if zusammen in wert:
                    wert = wert[zusammen]
                    i = j
                    gefunden = True
                    break
            if gefunden:
                continue
            return None
        return None
    return wert


def zustand(wert, warn, krit):
    """Schwellen. Steht krit unter warn, wird umgekehrt gezaehlt - "freier
    Speicher" ist schlecht, wenn er KLEIN wird, Ticketzahlen wenn sie gross
    werden. Beides soll ohne Zusatzschalter funktionieren."""
    if wert is None or not isinstance(wert, (int, float)):
        return "unknown"
    if warn is None and krit is None:
        return "ok"
    runter = (krit is not None and warn is not None and krit < warn)
    if runter:
        if krit is not None and wert <= krit: return "crit"
        if warn is not None and wert <= warn: return "warn"
        return "ok"
    if krit is not None and wert >= krit: return "crit"
    if warn is not None and wert >= warn: return "warn"
    return "ok"


def zahl(text):
    try:
        return float(text) if text not in (None, "") else None
    except ValueError:
        return None


# --- Abruf ------------------------------------------------------------------
def abrufen(abschnitt, c):
    url = c.get("url", "").strip()
    if not url:
        raise RuntimeError("url fehlt")
    headers, query = kopfzeilen(c.get("auth", ""))
    if query:
        trenner = "&" if "?" in url else "?"
        url = f"{url}{trenner}{urllib.parse.quote(query[0])}={urllib.parse.quote(query[1])}"
    headers.setdefault("Accept", "application/json")
    headers.setdefault("User-Agent", "NOCSignage-Connect/1.0")
    req = urllib.request.Request(url, headers=headers, method="GET")
    with urllib.request.urlopen(req, timeout=TIMEOUT, context=SSL_CTX) as r:
        roh = r.read().decode("utf-8", "replace")
    try:
        return json.loads(roh)
    except json.JSONDecodeError:
        raise RuntimeError("Antwort ist kein JSON: " + roh[:120].replace("\n", " "))


def eine_kachel(name, c):
    daten = abrufen(name, c)
    kachel = {
        "id": name,
        "titel": c.get("titel", name),
        "gruppe": c.get("gruppe", "Anwendungen"),
        "einheit": c.get("einheit", ""),
        "link": c.get("link", ""),
    }

    liste_pfad = c.get("liste", "").strip()
    if liste_pfad:
        # Listenform: mehrere Zeilen, z. B. die neuesten Tickets.
        eintraege = hole(daten, liste_pfad)
        if eintraege is None:
            raise RuntimeError(schluessel_hinweis(liste_pfad, daten))
        if not isinstance(eintraege, list):
            raise RuntimeError(f"'{liste_pfad}' ist keine Liste, sondern "
                               f"{type(eintraege).__name__}")
        max_n = int(c.get("max", "6"))
        kachel["eintraege"] = [{
            "titel": str(hole(e, c.get("eintrag_titel", "")) or "")[:120],
            "text":  str(hole(e, c.get("eintrag_text", "")) or "")[:120],
        } for e in eintraege[:max_n]]
        kachel["wert"] = len(eintraege)
        kachel["state"] = zustand(len(eintraege), zahl(c.get("warn")), zahl(c.get("krit")))
        return kachel

    wert_pfad = c.get("wert", "").strip()
    wert = hole(daten, wert_pfad)
    # Ein Pfad, der ins Leere zeigt, ist ein Konfigurationsfehler - kein
    # Messwert "unbekannt". Wuerde er nur als unklare Kachel durchgehen,
    # faende ihn niemand: die Wand saehe aus, als sei die Anwendung nur
    # gerade still. Darum hier hart abbrechen, mit den echten Schluesseln
    # der Antwort als Hinweis.
    if wert is None and wert_pfad:
        raise RuntimeError(schluessel_hinweis(wert_pfad, daten))
    if isinstance(wert, bool):
        wert = int(wert)
    kachel["wert"] = wert
    kachel["state"] = zustand(wert, zahl(c.get("warn")), zahl(c.get("krit")))
    if kachel["state"] == "unknown" and wert is not None:
        # Kein Zahlenwert, aber etwas da - als Text anzeigen statt "unklar".
        kachel["text"] = str(wert)[:120]
        kachel["state"] = c.get("text_state", "ok")
    return kachel


def schluessel_hinweis(pfad, daten):
    """Sagt nicht nur, dass der Pfad nicht passt, sondern was stattdessen da
    ist. Genau daran scheitert sonst jede erste Anbindung."""
    if isinstance(daten, dict):
        vorhanden = ", ".join(list(daten.keys())[:12]) or "(leeres Objekt)"
        return (f"Pfad '{pfad}' kommt in der Antwort nicht vor. "
                f"Vorhanden ist: {vorhanden}")
    if isinstance(daten, list):
        return (f"Pfad '{pfad}' kommt nicht vor - die Antwort ist eine Liste "
                f"mit {len(daten)} Eintraegen. Fuer die Anzahl: 'len:'")
    return f"Pfad '{pfad}' kommt in der Antwort nicht vor."


def lade_config():
    if not CONF_FILE.exists():
        return None
    c = configparser.ConfigParser(interpolation=None)
    c.read(CONF_FILE, encoding="utf-8")
    return c


def schreibe(kacheln, fehler):
    OUT_FILE.parent.mkdir(parents=True, exist_ok=True)
    n = lambda z: sum(1 for k in kacheln if k.get("state") == z)
    doc = {
        "generated": datetime.now(timezone.utc).isoformat(),
        "summary": {"total": len(kacheln), "ok": n("ok"), "warn": n("warn"),
                    "crit": n("crit"), "fehler": len(fehler)},
        "tiles": kacheln,
        "errors": fehler,
    }
    tmp = OUT_FILE.with_suffix(".tmp")
    tmp.write_text(json.dumps(doc, ensure_ascii=False))
    tmp.replace(OUT_FILE)


def durchlauf(conf):
    kacheln, fehler = [], []
    for name in conf.sections():
        c = conf[name]
        if c.get("aktiv", "true").lower() in ("0", "false", "nein", "no"):
            continue
        try:
            k = eine_kachel(name, c)
            kacheln.append(k)
            log(f"  [{k['state']}] {k['titel']}: {k.get('wert')} {k.get('einheit','')}".rstrip())
        except Exception as e:
            fehler.append({"id": name, "titel": c.get("titel", name),
                           "fehler": str(e)[:200]})
            log(f"  [FEHLER] {c.get('titel', name)}: {e}")
    # Sortierung: kaputt zuerst, dann Warnung - wie ueberall auf der Wand.
    rang = {"crit": 0, "warn": 1, "unknown": 2, "ok": 3}
    kacheln.sort(key=lambda k: (rang.get(k.get("state"), 9), k["titel"]))
    schreibe(kacheln, fehler)
    return kacheln, fehler


def main():
    conf = lade_config()

    if conf is None or not conf.sections():
        log(f"{CONF_FILE} fehlt oder enthaelt keinen Abschnitt - nichts "
            "anzubinden. Anlegen mit: ./scripts/add.sh anwendung")
        if "--test" in sys.argv:
            return 0
        # Trotzdem eine gueltige, leere Datei schreiben und den Zeitstempel
        # weiter auffrischen. Zwei Gruende:
        #   1. /kennzahlen/ bekommt ein leeres Dokument statt HTTP 404 und kann
        #      erklaeren, wie man etwas hinzufuegt.
        #   2. Der Healthcheck prueft, ob /state/connect.json frisch ist. Ohne
        #      dieses Schreiben gilt ein korrekt arbeitender Dienst fuer immer
        #      als "startet noch" - genau das ist passiert, weil die aus der
        #      Vorlage kopierte ini-Datei existiert, aber nur Kommentare
        #      enthaelt.
        while True:
            schreibe([], [])
            if "--once" in sys.argv:
                return 0
            time.sleep(INTERVAL)

    if "--test" in sys.argv:
        i = sys.argv.index("--test")
        name = sys.argv[i + 1] if len(sys.argv) > i + 1 else None
        namen = [name] if name else conf.sections()
        schlecht = 0
        for nm in namen:
            if nm not in conf:
                log(f"'{nm}' steht nicht in {CONF_FILE}"); schlecht += 1; continue
            try:
                k = eine_kachel(nm, conf[nm])
                log(f"OK  {k['titel']}: {k.get('wert')} {k.get('einheit','')} "
                    f"-> {k['state']}".rstrip())
                if k.get("eintraege"):
                    for e in k["eintraege"][:3]:
                        log(f"      · {e['titel']}")
            except Exception as e:
                log(f"FEHLER  {nm}: {e}")
                if "fehlt in config/secrets.env" in str(e):
                    log("        -> Variablennamen in connect.ini und Eintrag in "
                        "secrets.env vergleichen")
                if "kommt in der Antwort nicht vor" in str(e):
                    log("        -> Pfad in config/connect.ini anpassen; die "
                        "vorhandenen Schluessel stehen oben")
                if "CERTIFICATE_VERIFY_FAILED" in str(e):
                    log("        -> Firmen-CA fehlt, oder CONNECT_VERIFY_TLS=false "
                        "setzen (bewusste Entscheidung)")
                schlecht += 1
        return 1 if schlecht else 0

    log(f"Universalanschluss: {len(conf.sections())} Anwendung(en), alle {INTERVAL}s")
    einzeln = "--once" in sys.argv
    while True:
        try:
            kacheln, fehler = durchlauf(conf)
            log(f"Durchlauf fertig: {len(kacheln)} Kachel(n), {len(fehler)} Fehler")
        except Exception as e:
            log(f"Durchlauf abgebrochen: {e}")
        if einzeln:
            return 0
        time.sleep(INTERVAL)


if __name__ == "__main__":
    sys.exit(main() or 0)

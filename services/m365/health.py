#!/usr/bin/env python3
"""
Microsoft 365 Service Health - die ECHTE Lage eures Tenants.

WARUM DIESER DIENST UEBERHAUPT:
Einen oeffentlichen Service-Health-Feed gibt es nicht mehr. Was oeffentlich
bleibt, meldet Aenderungen und Releases - keine Stoerungen. Was EUREN Tenant
trifft, steht ausschliesslich im Service Health Dashboard, und daran kommt man
nur ueber die Graph-API.

SICHERHEIT - die drei Entscheidungen, die hier drinstecken:
  1. Genau EINE Berechtigung: ServiceHealth.Read.All (Application). Damit kann
     dieser Dienst Dienstzustaende lesen und sonst nichts - keine Postfaecher,
     keine Benutzer, keine Dateien.
  2. Das Client-Secret verlaesst den Container nie. Es steht in
     config/secrets.env, wird nur fuer den Token-Abruf benutzt, und in die
     ausgelieferte JSON-Datei kommt ausschliesslich der Zustand.
  3. Nur Lesen. Der Dienst ruft ausschliesslich GET-Endpunkte auf.

Nur Standardbibliothek - keine Abhaengigkeiten, kein pip im Container.

    python health.py           # Dauerbetrieb
    python health.py --once    # ein Durchlauf
    python health.py --test    # Anmeldung pruefen, nichts schreiben
"""
import json, os, ssl, sys, time, urllib.error, urllib.parse, urllib.request
from datetime import datetime, timezone
from pathlib import Path

TENANT   = (os.getenv("M365_TENANT_ID") or "").strip()
CLIENT   = (os.getenv("M365_CLIENT_ID") or "").strip()
SECRET   = (os.getenv("M365_CLIENT_SECRET") or "").strip()
OUT_FILE = Path(os.getenv("M365_OUT_FILE", "/state/m365.json"))
INTERVAL = int(os.getenv("M365_POLL_SECONDS", "300"))
# Nur Dienste, die euch interessieren (leer = alle). Kommagetrennt, z. B.
# "Exchange Online,SharePoint Online,Microsoft Teams"
NUR      = [x.strip().lower() for x in os.getenv("M365_SERVICES", "").split(",") if x.strip()]
CORP_CA  = os.getenv("CORP_CA_FILE", "").strip()

GRAPH  = "https://graph.microsoft.com/v1.0"
SCOPE  = "https://graph.microsoft.com/.default"


def log(msg):
    print(f"{datetime.now(timezone.utc):%Y-%m-%dT%H:%M:%SZ}  {msg}", flush=True)


# TLS wie in den anderen Diensten: Firmen-CAs ZUSAETZLICH zum System-Store.
# Bewusst nicht ueber SSL_CERT_FILE - die Variable wertet OpenSSL selbst aus
# und ERSETZT den Store, statt ihn zu ergaenzen.
SSL_CTX = ssl.create_default_context()
_geladen = []
for _ca in (x.strip() for x in CORP_CA.split(":") if x.strip()):
    if Path(_ca).is_file():
        try:
            SSL_CTX.load_verify_locations(_ca)
            _geladen.append(_ca)
        except Exception as e:
            log(f"WARNUNG: CA-Datei {_ca} nicht ladbar: {e}")


def http(url, *, daten=None, headers=None, timeout=30):
    req = urllib.request.Request(url, data=daten, method="POST" if daten else "GET",
                                 headers=headers or {})
    with urllib.request.urlopen(req, timeout=timeout, context=SSL_CTX) as r:
        return json.loads(r.read().decode("utf-8"))


def hole_token():
    """Client-Credentials-Flow. Der Token gilt rund eine Stunde."""
    url = f"https://login.microsoftonline.com/{TENANT}/oauth2/v2.0/token"
    daten = urllib.parse.urlencode({
        "client_id": CLIENT, "client_secret": SECRET,
        "scope": SCOPE, "grant_type": "client_credentials",
    }).encode()
    antwort = http(url, daten=daten,
                   headers={"Content-Type": "application/x-www-form-urlencoded"})
    return antwort["access_token"], int(antwort.get("expires_in", 3600))


def graph(pfad, token):
    return http(f"{GRAPH}{pfad}", headers={"Authorization": f"Bearer {token}",
                                           "Accept": "application/json"})


# Microsofts Statuswerte auf drei Stufen abbilden - die Wand kennt nur
# "laeuft", "beeintraechtigt", "gestoert".
ZUSTAND = {
    "serviceOperational": "ok",
    "investigating": "warn", "restoringService": "warn",
    "verifyingService": "warn", "serviceRestored": "ok",
    "postIncidentReviewPublished": "ok", "serviceDegradation": "warn",
    "serviceInterruption": "crit", "extendedRecovery": "warn",
    "falsePositive": "ok", "investigationSuspended": "warn",
    "resolved": "ok", "mitigatedExternal": "warn", "mitigated": "warn",
    "resolvedExternal": "ok", "confirmed": "crit", "reported": "warn",
}


def sammle(token):
    dienste = graph("/admin/serviceAnnouncement/healthOverviews", token).get("value", [])
    if NUR:
        dienste = [d for d in dienste if d.get("service", "").lower() in NUR]

    # Nur laufende Vorfaelle - behobene interessieren auf einer Wand nicht.
    roh = graph("/admin/serviceAnnouncement/issues"
                "?$filter=isResolved eq false&$top=50", token).get("value", [])

    vorfaelle = []
    for i in roh:
        vorfaelle.append({
            "id": i.get("id"),
            "service": i.get("service"),
            "title": i.get("title"),
            "classification": i.get("classification"),   # incident | advisory
            "status": i.get("status"),
            "state": ZUSTAND.get(i.get("status", ""), "warn"),
            "startDateTime": i.get("startDateTime"),
            "lastModifiedDateTime": i.get("lastModifiedDateTime"),
            "feature": i.get("feature"),
        })

    eintraege = []
    for d in dienste:
        name = d.get("service", "")
        zustand = ZUSTAND.get(d.get("status", ""), "warn")
        offen = [v for v in vorfaelle if v["service"] == name]
        # Ein laufender Vorfall wiegt schwerer als die Uebersichtsangabe:
        # Microsoft meldet dort gern noch "operational", waehrend ein Incident
        # laeuft. Die Wand soll den schlechteren Wert zeigen.
        if any(v["state"] == "crit" for v in offen):
            zustand = "crit"
        elif offen and zustand == "ok":
            zustand = "warn"
        eintraege.append({
            "service": name, "status": d.get("status"), "state": zustand,
            "incidents": len([v for v in offen if v["classification"] == "incident"]),
            "advisories": len([v for v in offen if v["classification"] == "advisory"]),
        })

    eintraege.sort(key=lambda e: ({"crit": 0, "warn": 1, "ok": 2}[e["state"]], e["service"]))
    n = lambda z: sum(1 for e in eintraege if e["state"] == z)
    return {
        "generated": datetime.now(timezone.utc).isoformat(),
        "summary": {
            "total": len(eintraege), "ok": n("ok"), "warn": n("warn"), "crit": n("crit"),
            "incidents": sum(1 for v in vorfaelle if v["classification"] == "incident"),
            "advisories": sum(1 for v in vorfaelle if v["classification"] == "advisory"),
        },
        "services": eintraege,
        "issues": sorted(vorfaelle, key=lambda v: v.get("lastModifiedDateTime") or "",
                         reverse=True)[:12],
    }


def schreibe(doc):
    OUT_FILE.parent.mkdir(parents=True, exist_ok=True)
    tmp = OUT_FILE.with_suffix(".tmp")
    tmp.write_text(json.dumps(doc, ensure_ascii=False))
    tmp.replace(OUT_FILE)          # atomar - die Wand liest im Sekundentakt


def fehler_hinweis(e):
    t = str(e)
    if "AADSTS7000215" in t: return "Client-Secret falsch oder abgelaufen."
    if "AADSTS700016" in t:  return "Anwendungs-ID (Client-ID) unbekannt in diesem Tenant."
    if "AADSTS90002" in t:   return "Tenant-ID unbekannt."
    if "Authorization_RequestDenied" in t or "403" in t:
        return ("Berechtigung fehlt. Noetig: ServiceHealth.Read.All als "
                "ANWENDUNGSberechtigung - und die Administratoreinwilligung "
                "muss erteilt sein.")
    if "CERTIFICATE_VERIFY_FAILED" in t:
        return "Zertifikat nicht pruefbar - Firmen-CA in CORP_CA_FILE eintragen."
    return ""


def einmal():
    token, gueltig = hole_token()
    doc = sammle(token)
    schreibe(doc)
    s = doc["summary"]
    log(f"{s['total']} Dienste: {s['ok']} ok, {s['warn']} beeintraechtigt, "
        f"{s['crit']} gestoert | {s['incidents']} Vorfaelle, {s['advisories']} Hinweise")
    for e in doc["services"]:
        if e["state"] != "ok":
            log(f"  [{e['state']}] {e['service']}: {e['status']} "
                f"({e['incidents']} Vorfaelle)")
    return gueltig


def main():
    if not (TENANT and CLIENT and SECRET):
        log("M365_TENANT_ID / M365_CLIENT_ID / M365_CLIENT_SECRET fehlen in "
            "config/secrets.env - dieser Dienst bleibt still.")
        # Kein Fehlercode: ohne Zugangsdaten ist Nichtstun das richtige
        # Verhalten, nicht eine Neustartschleife.
        while True:
            time.sleep(3600)

    log(f"M365 Service Health | Tenant {TENANT[:8]}… | alle {INTERVAL}s"
        + (f" | nur: {', '.join(NUR)}" if NUR else " | alle Dienste")
        + (f" | {len(_geladen)} Firmen-CA(s)" if _geladen else ""))

    if "--test" in sys.argv:
        try:
            token, gueltig = hole_token()
            log(f"Anmeldung erfolgreich, Token {gueltig}s gueltig.")
            d = graph("/admin/serviceAnnouncement/healthOverviews", token)
            log(f"Berechtigung ok: {len(d.get('value', []))} Dienste lesbar.")
            return 0
        except Exception as e:
            log(f"FEHLGESCHLAGEN: {e}")
            h = fehler_hinweis(e)
            if h: log(f"  -> {h}")
            return 1

    einzeln = "--once" in sys.argv
    while True:
        try:
            einmal()
        except Exception as e:
            log(f"Durchlauf fehlgeschlagen: {e}")
            h = fehler_hinweis(e)
            if h: log(f"  -> {h}")
        if einzeln:
            return 0
        time.sleep(INTERVAL)


if __name__ == "__main__":
    sys.exit(main() or 0)

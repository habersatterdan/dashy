#!/usr/bin/env python3
"""
Betriebslage-Sonde: misst selbst, statt Nachrichten zu lesen.

Warum es das gibt: RSS-Feeds erzaehlen, was in der Welt passiert. Beim
Vorbeilaufen an der Wand will man aber wissen, ob die EIGENEN Systeme laufen.
Diese Sonde prueft in kurzen Abstaenden jede Zeile aus config/probes.txt und
schreibt das Ergebnis nach /state/probe.json. Nginx liefert die Datei unter
/data/probe.json aus, die Wand (/lage/) rendert sie.

Bewusst nur Standardbibliothek - keine Abhaengigkeiten, laeuft auf jedem
python:3.12-alpine ohne pip install.

Geprueft wird je nach Ziel-Schema:
  https://...   Statuscode + Antwortzeit + Restlaufzeit des Zertifikats
  http://...    Statuscode + Antwortzeit
  tcp://host:p  Port erreichbar + Verbindungszeit
  dns://name    Namensaufloesung + Dauer
"""
import json, os, socket, ssl, sys, time, urllib.error, urllib.request
from datetime import datetime, timezone
from pathlib import Path

PROBES_FILE  = Path(os.getenv("PROBES_FILE", "/config/probes.txt"))
OUT_FILE     = Path(os.getenv("OUT_FILE", "/state/probe.json"))
HIST_FILE    = Path(os.getenv("HIST_FILE", "/state/probe-history.json"))
INTERVAL     = int(os.getenv("PROBE_INTERVAL", "60"))
TIMEOUT      = float(os.getenv("PROBE_TIMEOUT", "8"))
SLOW_MS      = int(os.getenv("PROBE_SLOW_MS", "2000"))     # darueber: Warnung
CERT_WARN    = int(os.getenv("PROBE_CERT_WARN_DAYS", "30"))
CERT_CRIT    = int(os.getenv("PROBE_CERT_CRIT_DAYS", "7"))
HIST_POINTS  = int(os.getenv("PROBE_HISTORY_POINTS", "120"))
VERIFY_TLS   = os.getenv("PROBE_VERIFY_TLS", "false").lower() in ("1", "true", "yes")
CORP_CA_FILE = os.getenv("CORP_CA_FILE", "").strip()


def log(msg):
    print(f"{datetime.now(timezone.utc):%Y-%m-%dT%H:%M:%SZ}  {msg}", flush=True)


# --- TLS ---------------------------------------------------------------------
# Interne Zertifikate sind der Normalfall; die Erreichbarkeit soll nicht an
# einer fehlenden CA scheitern. Die Restlaufzeit lesen wir trotzdem aus - das
# geht auch ohne Verifikation.
def make_ctx(verify):
    ctx = ssl.create_default_context()
    for ca in (p.strip() for p in CORP_CA_FILE.split(":") if p.strip()):
        if Path(ca).is_file():
            try:
                ctx.load_verify_locations(ca)
            except Exception:
                pass
    if not verify:
        ctx.check_hostname = False
        ctx.verify_mode = ssl.CERT_NONE
    return ctx


CTX = make_ctx(VERIFY_TLS)


def load_probes():
    """config/probes.txt -> [{name, group, target}]"""
    if not PROBES_FILE.exists():
        log(f"WARNUNG: {PROBES_FILE} fehlt - es wird nichts geprueft.")
        return []
    out = []
    for line in PROBES_FILE.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        parts = [p.strip() for p in line.split("|")]
        if len(parts) < 3 or not parts[2]:
            log(f"  Zeile uebersprungen (erwartet 'Name | Gruppe | Ziel'): {line}")
            continue
        out.append({"name": parts[0], "group": parts[1], "target": parts[2]})
    return out


def cert_days_left(host, port):
    """Resttage des Serverzertifikats. None, wenn nicht ermittelbar."""
    try:
        ctx = ssl.create_default_context()
        ctx.check_hostname = False
        ctx.verify_mode = ssl.CERT_NONE
        with socket.create_connection((host, port), timeout=TIMEOUT) as sock:
            with ctx.wrap_socket(sock, server_hostname=host) as tls:
                # Ohne Verifikation liefert getpeercert() ein leeres dict; das
                # DER-Zertifikat laesst sich aber immer lesen.
                der = tls.getpeercert(binary_form=True)
        if not der:
            return None
        # Minimaler DER-Scan nach dem notAfter-Zeitstempel (UTCTime, Tag 0x17).
        # Reicht voellig und vermeidet eine Abhaengigkeit auf cryptography.
        import re
        m = re.findall(rb"\x17\x0d(\d{12}Z)", der)
        if not m:
            return None
        raw = m[-1].decode()          # letzter Zeitstempel = notAfter
        year = 2000 + int(raw[0:2])
        exp = datetime(year, int(raw[2:4]), int(raw[4:6]), int(raw[6:8]),
                       int(raw[8:10]), int(raw[10:12]), tzinfo=timezone.utc)
        return round((exp - datetime.now(timezone.utc)).total_seconds() / 86400, 1)
    except Exception:
        return None


def check_http(url):
    verify_tls = url.startswith("https://")
    req = urllib.request.Request(url, method="GET", headers={
        "User-Agent": "NOCSignage-Probe/1.0", "Accept": "*/*"})
    t0 = time.monotonic()
    status, err = None, None
    try:
        with urllib.request.urlopen(req, timeout=TIMEOUT, context=CTX) as r:
            r.read(2048)
            status = r.status
    except urllib.error.HTTPError as e:
        # 401/403 heisst: der Dienst LEBT, er will nur Anmeldung. Das ist kein
        # Ausfall - genau diese Unterscheidung macht die Wand brauchbar.
        status = e.code
    except Exception as e:
        err = str(e)
    ms = round((time.monotonic() - t0) * 1000)

    days = None
    if verify_tls:
        from urllib.parse import urlsplit
        u = urlsplit(url)
        days = cert_days_left(u.hostname, u.port or 443)

    if err:
        return dict(state="crit", ms=None, http_status=None, cert_days=days,
                    message=short_error(err))
    if status >= 500:
        return dict(state="crit", ms=ms, http_status=status, cert_days=days,
                    message=f"HTTP {status}")
    state, msg = "ok", f"HTTP {status}"
    if status in (401, 403):
        msg = f"HTTP {status} (erreichbar, Anmeldung noetig)"
    elif status >= 400:
        state, msg = "warn", f"HTTP {status}"
    if ms > SLOW_MS:
        state = "warn" if state == "ok" else state
        msg += f" - langsam ({ms} ms)"
    if days is not None:
        if days < CERT_CRIT:
            state, msg = "crit", f"Zertifikat laeuft in {days:.0f} Tagen ab"
        elif days < CERT_WARN and state == "ok":
            state, msg = "warn", f"Zertifikat laeuft in {days:.0f} Tagen ab"
    return dict(state=state, ms=ms, http_status=status, cert_days=days, message=msg)


def check_tcp(target):
    hostport = target.split("://", 1)[1]
    host, _, port = hostport.partition(":")
    try:
        port = int(port or 0)
    except ValueError:
        return dict(state="crit", ms=None, http_status=None, cert_days=None,
                    message=f"ungueltiger Port in '{target}'")
    if not port:
        return dict(state="crit", ms=None, http_status=None, cert_days=None,
                    message="Port fehlt (tcp://host:port)")
    t0 = time.monotonic()
    try:
        with socket.create_connection((host, port), timeout=TIMEOUT):
            pass
    except Exception as e:
        return dict(state="crit", ms=None, http_status=None, cert_days=None,
                    message=short_error(str(e)))
    ms = round((time.monotonic() - t0) * 1000)
    days = cert_days_left(host, port) if port in (443, 636, 993, 995, 8443) else None
    state, msg = "ok", f"Port {port} offen"
    if ms > SLOW_MS:
        state, msg = "warn", f"Port {port} offen - langsam ({ms} ms)"
    if days is not None and days < CERT_CRIT:
        state, msg = "crit", f"Zertifikat laeuft in {days:.0f} Tagen ab"
    elif days is not None and days < CERT_WARN and state == "ok":
        state, msg = "warn", f"Zertifikat laeuft in {days:.0f} Tagen ab"
    return dict(state=state, ms=ms, http_status=None, cert_days=days, message=msg)


def check_dns(target):
    name = target.split("://", 1)[1].strip("/")
    t0 = time.monotonic()
    try:
        addrs = sorted({a[4][0] for a in socket.getaddrinfo(name, None)})
    except Exception as e:
        return dict(state="crit", ms=None, http_status=None, cert_days=None,
                    message=short_error(str(e)))
    ms = round((time.monotonic() - t0) * 1000)
    return dict(state="ok" if ms <= SLOW_MS else "warn", ms=ms, http_status=None,
                cert_days=None, message=", ".join(addrs[:3]))


def short_error(err):
    """Rohfehler auf eine Zeile bringen, die aus 5 Metern lesbar ist."""
    e = err.replace("\n", " ")
    table = [
        ("Name or service not known", "DNS-Name unbekannt"),
        ("Temporary failure in name resolution", "DNS antwortet nicht"),
        ("timed out", "Zeitueberschreitung"),
        ("Connection refused", "Verbindung abgelehnt"),
        ("No route to host", "Kein Weg zum Host"),
        ("Network is unreachable", "Netz nicht erreichbar"),
        ("CERTIFICATE_VERIFY_FAILED", "Zertifikat nicht verifizierbar"),
    ]
    for needle, text in table:
        if needle in e:
            return text
    return e[:90]


def check(probe):
    t = probe["target"]
    if t.startswith(("http://", "https://")):
        return check_http(t)
    if t.startswith("tcp://"):
        return check_tcp(t)
    if t.startswith("dns://"):
        return check_dns(t)
    return dict(state="unknown", ms=None, http_status=None, cert_days=None,
                message=f"unbekanntes Ziel-Schema in '{t}'")


def load_history():
    try:
        return json.loads(HIST_FILE.read_text())
    except Exception:
        return {}


def run_once(probes, history):
    results = []
    for p in probes:
        r = check(p)
        key = f"{p['name']}|{p['target']}"
        # Antwortzeit-Verlauf fuer die Sparkline; None = Ausfall, wird als
        # Luecke gezeichnet statt als 0 (eine 0 ms saehe aus wie "sehr schnell").
        hist = history.get(key, [])[-(HIST_POINTS - 1):] + [r["ms"]]
        history[key] = hist
        results.append({**p, **r, "history": hist})
    return results


def summarize(results):
    n = lambda s: sum(1 for r in results if r["state"] == s)
    return {"ok": n("ok"), "warn": n("warn"), "crit": n("crit"),
            "unknown": n("unknown"), "total": len(results)}


def write_out(results):
    OUT_FILE.parent.mkdir(parents=True, exist_ok=True)
    doc = {"generated": datetime.now(timezone.utc).isoformat(),
           "interval": INTERVAL,
           "summary": summarize(results),
           "targets": results}
    tmp = OUT_FILE.with_suffix(".tmp")
    tmp.write_text(json.dumps(doc, ensure_ascii=False))
    tmp.replace(OUT_FILE)          # atomar: die Wand liest nie eine halbe Datei


def main():
    once = "--once" in sys.argv
    probes = load_probes()
    log(f"Sonde: {len(probes)} Ziele | Intervall={INTERVAL}s | "
        f"langsam ab {SLOW_MS} ms | Zertifikatswarnung ab {CERT_WARN} Tagen")
    if not probes:
        log(f"Nichts zu tun. Lege {PROBES_FILE} an "
            f"(Vorlage: config/probes.txt.example).")
    history = load_history()
    while True:
        results = run_once(probes, history)
        s = summarize(results)
        write_out(results)
        try:
            HIST_FILE.write_text(json.dumps(history))
        except Exception as e:
            log(f"Verlauf nicht speicherbar: {e}")
        log(f"Durchlauf: {s['ok']} ok, {s['warn']} Warnung, {s['crit']} kritisch"
            + (f", {s['unknown']} unklar" if s["unknown"] else ""))
        for r in results:
            if r["state"] in ("crit", "warn"):
                log(f"  [{r['state']}] {r['name']}: {r['message']}")
        if once:
            return
        time.sleep(INTERVAL)


if __name__ == "__main__":
    main()

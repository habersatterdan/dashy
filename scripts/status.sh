#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Ein Befehl, der sagt, ob die Anlage gesund ist - und ob sie sicher steht.
#
#   ./scripts/status.sh            # Betrieb + Sicherheit
#   ./scripts/status.sh --kurz     # nur die Ampel
#
# Gedacht als taeglicher Blick und als das, was man anhaengt, wenn man um
# Hilfe bittet. Jede Zeile nennt bei Bedarf den naechsten Schritt - eine
# Pruefung, die nur "Fehler" sagt, hilft niemandem.
# -----------------------------------------------------------------------------
set -uo pipefail
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
G=$'\e[32m'; R=$'\e[31m'; Y=$'\e[33m'; B=$'\e[1m'; D=$'\e[0m'
GUT=0; WARN=0; SCHLECHT=0
ok(){   echo "  ${G}●${D} $*"; GUT=$((GUT+1)); }
warn(){ echo "  ${Y}▲${D} $*"; WARN=$((WARN+1)); }
bad(){  echo "  ${R}✕${D} $*"; SCHLECHT=$((SCHLECHT+1)); }
tipp(){ echo "      → $*"; }
titel(){ echo; echo "${B}$*${D}"; }

kurz="${1:-}"

# --- Container ---------------------------------------------------------------
titel "Container"
ps="$(docker compose ps --format '{{.Service}} {{.State}} {{.Status}}' 2>/dev/null)"
if [ -z "${ps}" ]; then
  bad "Kein Stack gestartet."; tipp "./scripts/update.sh"
else
  while read -r dienst zustand rest; do
    [ -z "${dienst}" ] && continue
    case "${rest}" in
      *unhealthy*) bad "${dienst}: ${rest}"; tipp "docker compose logs --tail 30 ${dienst}" ;;
      *health:\ starting*) warn "${dienst}: startet noch (${rest})" ;;
      *) case "${zustand}" in
           running) ok "${dienst}: laeuft" ;;
           restarting) bad "${dienst}: Neustartschleife"; tipp "docker compose logs --tail 30 ${dienst}" ;;
           *) bad "${dienst}: ${zustand}" ;;
         esac ;;
    esac
  done <<< "${ps}"
fi

# --- Erreichbarkeit ----------------------------------------------------------
titel "Wandseiten"
for pfad in /health /signage/ /lage/ /news/ /stoerungen/ /wall/ /woche/; do
  code="$(curl -sk -m 12 -o /dev/null -w '%{http_code}' "https://127.0.0.1${pfad}" 2>/dev/null)"
  case "${code}" in
    200) ok "${pfad}" ;;
    000) bad "${pfad}: keine Antwort"; tipp "docker compose logs --tail 20 nginx" ;;
    *)   bad "${pfad}: HTTP ${code}" ;;
  esac
done

# --- Daten -------------------------------------------------------------------
titel "Datenquellen"
if probe="$(curl -sk -m 12 https://127.0.0.1/data/probe.json 2>/dev/null)" && [ -n "${probe}" ]; then
  alter="$(python3 -c "
import json,sys,datetime
d=json.loads(sys.argv[1]); g=datetime.datetime.fromisoformat(d['generated'])
print(int((datetime.datetime.now(datetime.timezone.utc)-g).total_seconds()))" "${probe}" 2>/dev/null || echo 99999)"
  s="$(python3 -c "
import json,sys; d=json.loads(sys.argv[1])['summary']
print(d['ok'], d['warn'], d['crit'], d['total'])" "${probe}" 2>/dev/null)"
  set -- ${s}
  if [ "${alter}" -gt 300 ]; then
    bad "Sonde: Messung ${alter} s alt"; tipp "docker compose logs --tail 20 probe"
  elif [ "${4:-0}" = "0" ]; then
    warn "Sonde laeuft, aber keine Ziele konfiguriert"
    tipp "nano config/probes.txt   (dann: docker compose restart probe)"
  elif [ "${3:-0}" != "0" ] && [ "${1:-0}" = "0" ]; then
    warn "Alle ${4} Ziele kritisch - meist ein Konfigurationsfehler, kein Ausfall"
    tipp "docker compose exec probe python /app/probe.py --once"
  else
    ok "Sonde: ${1} ok, ${2} Warnung, ${3} kritisch (von ${4})"
  fi
else
  bad "Sonde liefert keine Daten"; tipp "docker compose logs --tail 20 probe"
fi

if curl -sk -m 12 https://127.0.0.1/data/cve.json >/dev/null 2>&1; then
  ok "CVE-Watcher hat einen Stand geschrieben"
else
  warn "CVE-Watcher: noch kein Fund seit dem letzten Start (normal)"
fi

code="$(curl -sk -m 15 -o /dev/null -w '%{http_code}' https://127.0.0.1/grafana/api/health 2>/dev/null)"
[ "${code}" = "200" ] && ok "Grafana antwortet" || { bad "Grafana: HTTP ${code}"; tipp "./scripts/check-grafana.sh"; }

# --- Sicherheit --------------------------------------------------------------
titel "Sicherheit"

# 1. Geheimnisse duerfen nicht fuer alle lesbar sein.
if [ -f config/secrets.env ]; then
  rechte="$(stat -c '%a' config/secrets.env 2>/dev/null)"
  case "${rechte}" in
    600|400) ok "config/secrets.env: Rechte ${rechte}" ;;
    *) bad "config/secrets.env ist mit ${rechte} zu offen"
       tipp "chmod 600 config/secrets.env" ;;
  esac
fi
for f in nginx/certs/*.key; do
  [ -e "${f}" ] || continue
  rechte="$(stat -c '%a' "${f}" 2>/dev/null)"
  case "${rechte}" in
    600|400) ok "$(basename "${f}"): Rechte ${rechte}" ;;
    *) bad "$(basename "${f}") ist mit ${rechte} zu offen"; tipp "chmod 600 ${f}" ;;
  esac
done

# 2. Nichts Geheimes darf je im Git landen.
if git ls-files --error-unmatch config/secrets.env >/dev/null 2>&1; then
  bad "config/secrets.env liegt IM GIT"
  tipp "git rm --cached config/secrets.env  (und Token danach neu erzeugen!)"
else
  ok "Geheimnisse sind nicht versioniert"
fi

# 3. Voreingestellte Passwoerter.
if grep -qE '^GRAFANA_ADMIN_PASSWORD=(admin|bitte-aendern)?$' .env 2>/dev/null; then
  bad "Grafana-Admin hat noch das Standardpasswort"
  tipp "GRAFANA_ADMIN_PASSWORD in .env setzen, dann ./scripts/update.sh"
else
  ok "Grafana-Admin: eigenes Passwort gesetzt"
fi

# 4. Der Zabbix-Proxy darf nur lesen duerfen.
if [ -f nginx/conf.d/extra/zabbix-api.conf ]; then
  if grep -q 'nur lesende Zabbix-Methoden' nginx/conf.d/extra/zabbix-api.conf; then
    ok "Zabbix-API: nur lesende Methoden erlaubt"
  else
    bad "Zabbix-API ohne Methodenfilter - der Token haengt an JEDER Anfrage"
    tipp "./scripts/render-config.py && ./scripts/update.sh"
  fi
  # Gegenprobe zur Laufzeit: eine schreibende Methode MUSS abgewiesen werden.
  antwort="$(curl -sk -m 10 -X POST https://127.0.0.1/api/zabbix \
      -H 'Content-Type: application/json' \
      -d '{"jsonrpc":"2.0","method":"host.delete","params":[],"id":1}' 2>/dev/null)"
  case "${antwort}" in
    *"nur lesende"*) ok "Gegenprobe: host.delete wird abgewiesen" ;;
    "")              warn "Gegenprobe nicht moeglich (nginx antwortet nicht)" ;;
    *)               bad "Gegenprobe: host.delete wurde NICHT abgewiesen!"
                     tipp "./scripts/render-config.py && ./scripts/update.sh" ;;
  esac
fi

# 4b. Riskante Dienste duerfen nicht ungefragt mitlaufen.
if docker compose ps --services --filter status=running 2>/dev/null | grep -qx watchtower; then
  warn "Watchtower laeuft - er hat den Docker-Socket und damit Root auf dem Pi"
  tipp "Fuer Updates genuegt ./scripts/update.sh. Abschalten: docker compose stop watchtower"
else
  ok "Watchtower laeuft nicht (kein Docker-Socket im Spiel)"
fi
if docker compose ps --services --filter status=running 2>/dev/null | grep -qx shotter; then
  warn "Shotter laeuft - Chromium rendert dort fremde Webseiten"
  tipp "Nur mit vertrauenswuerdigen SHOT_TARGETS betreiben"
else
  ok "Shotter laeuft nicht"
fi

# 4c. M365 - wenn eingerichtet, muss es auch liefern.
if grep -qE '^M365_TENANT_ID=.+' config/secrets.env 2>/dev/null; then
  if curl -sk -m 12 https://127.0.0.1/data/m365.json >/dev/null 2>&1; then
    ok "M365 Service Health liefert Daten"
  else
    bad "M365 ist eingerichtet, liefert aber nichts"
    tipp "docker compose exec m365 python /app/health.py --test"
  fi
fi

# 4d. Universalanschluss - Fehler dort sind stille Luecken auf der Wand.
if [ -f config/connect.ini ] && grep -qE '^\[' config/connect.ini; then
  n_app="$(grep -cE '^\[' config/connect.ini)"
  if curl -sk -m 12 https://127.0.0.1/data/connect.json 2>/dev/null \
       | grep -q '"tiles"'; then
    n_err="$(curl -sk -m 12 https://127.0.0.1/data/connect.json 2>/dev/null \
             | python3 -c 'import json,sys; print(len(json.load(sys.stdin).get("errors",[])))' 2>/dev/null)"
    if [ "${n_err:-0}" = "0" ]; then
      ok "Universalanschluss: ${n_app} Anwendung(en), alle erreichbar"
    else
      warn "Universalanschluss: ${n_err} von ${n_app} Anwendung(en) nicht erreichbar"
      tipp "docker compose exec connect python /app/connect.py --test"
    fi
  else
    bad "config/connect.ini ist gefuellt, aber /data/connect.json liefert nichts"
    tipp "docker compose logs --tail 30 connect"
  fi
fi

# 5. HTTP darf nur auf HTTPS umlenken, nichts ausliefern.
code="$(curl -s -m 10 -o /dev/null -w '%{http_code}' http://127.0.0.1/lage/ 2>/dev/null)"
case "${code}" in
  301|302) ok "HTTP lenkt auf HTTPS um" ;;
  200)     bad "HTTP liefert Inhalte aus (sollte umlenken)" ;;
  *)       warn "HTTP antwortet mit ${code}" ;;
esac

# 6. Admin-Bereich muss geschuetzt sein.
code="$(curl -sk -m 10 -o /dev/null -w '%{http_code}' https://127.0.0.1/admin 2>/dev/null)"
case "${code}" in
  401) ok "/admin verlangt Anmeldung" ;;
  404) warn "/admin nicht vorhanden" ;;
  *)   bad "/admin antwortet mit ${code} statt 401"
       tipp "nginx/certs/.htpasswd anlegen (siehe README)" ;;
esac

# 7. Zertifikatsrestlaufzeit des eigenen Webzertifikats.
if [ -f nginx/certs/signage.crt ]; then
  bis="$(openssl x509 -enddate -noout -in nginx/certs/signage.crt 2>/dev/null | cut -d= -f2)"
  tage="$(( ( $(date -d "${bis}" +%s 2>/dev/null || echo 0) - $(date +%s) ) / 86400 ))"
  if [ "${tage}" -lt 0 ]; then bad "Eigenes Zertifikat ist abgelaufen"
  elif [ "${tage}" -lt 30 ]; then warn "Eigenes Zertifikat laeuft in ${tage} Tagen ab"
  else ok "Eigenes Zertifikat: noch ${tage} Tage gueltig"; fi
fi

# --- Platz und Sicherung -----------------------------------------------------
titel "System"
frei="$(df -P . | awk 'NR==2{print $5}' | tr -d '%')"
if [ "${frei}" -ge 90 ]; then bad "Datentraeger zu ${frei} % voll"
elif [ "${frei}" -ge 80 ]; then warn "Datentraeger zu ${frei} % voll"
else ok "Datentraeger: ${frei} % belegt"; fi

if [ -d backups ] && [ -n "$(ls -A backups 2>/dev/null)" ]; then
  neueste="$(ls -t backups | head -1)"
  alter_tage="$(( ( $(date +%s) - $(stat -c %Y "backups/${neueste}") ) / 86400 ))"
  [ "${alter_tage}" -le 2 ] && ok "Sicherung: ${neueste} (vor ${alter_tage} Tagen)" \
    || warn "Juengste Sicherung ist ${alter_tage} Tage alt"
else
  warn "Keine Sicherung gefunden"; tipp "./scripts/backup.sh"
fi

# --- Ampel -------------------------------------------------------------------
echo
if [ "${SCHLECHT}" -gt 0 ]; then
  echo "${R}${B}✕ ${SCHLECHT} Problem(e)${D}, ${WARN} Hinweis(e), ${GUT} in Ordnung."
  exit 1
elif [ "${WARN}" -gt 0 ]; then
  echo "${Y}${B}▲ ${WARN} Hinweis(e)${D}, ${GUT} in Ordnung - Betrieb laeuft."
else
  echo "${G}${B}● Alles in Ordnung${D} (${GUT} Pruefungen)."
fi

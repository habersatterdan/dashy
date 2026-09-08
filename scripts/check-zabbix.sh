#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Zabbix-Anbindung Schicht fuer Schicht pruefen.
#
# Warum schichtweise: "Das Dashboard bleibt leer" kann sechs verschiedene
# Ursachen haben - DNS, Routing, TLS, Anmeldung, X-Frame-Options oder ein
# Tippfehler im Proxy. Wer alles auf einmal probiert, raet. Dieses Skript
# geht von unten nach oben und stoppt gedanklich bei der ersten roten Zeile:
# alles darueber ist Folgefehler.
#
#   ./scripts/check-zabbix.sh
# -----------------------------------------------------------------------------
set -uo pipefail
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

G=$'\e[32m'; R=$'\e[31m'; Y=$'\e[33m'; D=$'\e[0m'
ok(){   echo "  ${G}OK${D}    $*"; }
fail(){ echo "  ${R}FEHLER${D} $*"; FAILED=1; }
warn(){ echo "  ${Y}HINWEIS${D} $*"; }
step(){ echo; echo "== $*"; }
FAILED=0

# --- Konfiguration lesen -----------------------------------------------------
ZABBIX_URL="$(grep -E '^ZABBIX_URL=' config/endpoints.env 2>/dev/null | cut -d= -f2- | tr -d '"')"
TOKEN="$(grep -E '^ZABBIX_API_TOKEN=' config/secrets.env 2>/dev/null | cut -d= -f2- | tr -d '"')"

step "1. Konfiguration"
if [ -z "${ZABBIX_URL}" ]; then
  fail "ZABBIX_URL fehlt in config/endpoints.env"
  echo "         Eintragen, dann ./scripts/render-config.py"
  exit 1
fi
ok "ZABBIX_URL = ${ZABBIX_URL}"

# Eine aus der Adresszeile kopierte Dashboard-URL ist der haeufigste Fehler.
# Sie sieht richtig aus, aber jeder API-Aufruf landet dann auf der HTML-Seite,
# und Zabbix antwortet mit "You are not logged in" statt mit JSON.
case "${ZABBIX_URL}" in
  *\?*|*.php*)
    warn "ZABBIX_URL enthaelt eine Seite bzw. Parameter."
    echo "         Hier gehoert nur die BASIS hinein, z. B.:"
    echo "             ZABBIX_URL=http://server.firma.local/zabbix"
    echo "         Die Dashboard-URL kommt spaeter in assets/signage.html." ;;
esac
if [ -z "${TOKEN}" ] || [ "${TOKEN}" = "REPLACE_WITH_ZABBIX_API_TOKEN" ]; then
  warn "ZABBIX_API_TOKEN fehlt in config/secrets.env - die Problemliste bleibt leer."
else
  ok "API-Token hinterlegt (${#TOKEN} Zeichen)"
fi

# Bereinigte Basis: ohne Query, ohne Seitenname - genau das, was
# scripts/render-config.py aus derselben Eingabe macht.
BASE="$(echo "${ZABBIX_URL}" | sed -E 's#[?#].*$##; s#/[^/]*\.php$##; s#/+$##')"
[ "${BASE}" != "${ZABBIX_URL}" ] && ok "bereinigte Basis = ${BASE}"
HOST="$(echo "${BASE}" | sed -E 's#^[a-z]+://##; s#[:/].*$##')"
PORT="$(echo "${BASE}" | sed -nE 's#^[a-z]+://[^:/]+:([0-9]+).*$#\1#p')"
[ -z "${PORT}" ] && { case "${BASE}" in https://*) PORT=443;; *) PORT=80;; esac; }
ok "Host = ${HOST}   Port = ${PORT}"
case "${HOST}" in
  *.*) : ;;
  *)   warn "'${HOST}' ist ein Kurzname ohne Punkt. Im Container loest der fast"
       echo "         sicher nicht auf - die Suchdomaene des Firmennetzes kennt"
       echo "         Docker nicht. Trage den vollen Namen (FQDN) ein." ;;
esac

# --- Schicht 2: DNS ----------------------------------------------------------
step "2. Namensaufloesung"
if getent hosts "${HOST}" >/dev/null 2>&1; then
  ok "auf dem Pi:        $(getent hosts "${HOST}" | head -1)"
else
  fail "auf dem Pi:        '${HOST}' loest nicht auf"
  echo "         Pruefen:  getent hosts ${HOST}   /   cat /etc/resolv.conf"
  echo "         Ausweg 1: vollen FQDN in config/endpoints.env eintragen"
  echo "         Ausweg 2: IP-Adresse statt Name eintragen"
fi

if docker compose ps --status running --services 2>/dev/null | grep -qx nginx; then
  if docker compose exec -T nginx getent hosts "${HOST}" >/dev/null 2>&1; then
    ok "im nginx-Container: $(docker compose exec -T nginx getent hosts "${HOST}" | head -1 | tr -d '\r')"
  else
    fail "im nginx-Container: '${HOST}' loest nicht auf"
    echo "         Der Container nutzt Dockers DNS, nicht die Suchdomaene des Pi."
    IP="$(getent hosts "${HOST}" 2>/dev/null | awk '{print $1; exit}')"
    FQ="$(getent hosts "${HOST}" 2>/dev/null | awk '{print $2; exit}')"
    if [ -n "${FQ}" ] && [ "${FQ}" != "${HOST}" ]; then
      echo "         Bester Weg: in config/endpoints.env den vollen Namen nutzen:"
      echo "             ZABBIX_URL=http://${FQ}$(echo "${BASE}" | sed -E 's#^[a-z]+://[^/]*##')"
    fi
    if [ -n "${IP}" ]; then
      echo "         Falls auch das nicht reicht: in .env eintragen (kein YAML noetig)"
      echo "             EXTRA_HOST_1=${FQ:-${HOST}}:${IP}"
      echo "         danach ./scripts/update.sh"
    fi
  fi
else
  warn "nginx laeuft nicht - Containerpruefungen uebersprungen."
fi

# --- Schicht 3: Erreichbarkeit ----------------------------------------------
step "3. Port und TLS"
if command -v nc >/dev/null 2>&1 && nc -z -w3 "${HOST}" "${PORT}" 2>/dev/null; then
  ok "Port ${PORT} auf ${HOST} erreichbar"
elif timeout 3 bash -c ">/dev/tcp/${HOST}/${PORT}" 2>/dev/null; then
  ok "Port ${PORT} auf ${HOST} erreichbar"
else
  fail "Port ${PORT} auf ${HOST} nicht erreichbar (Firewall? falscher Port?)"
fi

# --- Schicht 4: HTTP + X-Frame-Options --------------------------------------
step "4. Antwort von Zabbix"
HDR="$(curl -sk -m 10 -D- -o /dev/null "${BASE}/" 2>/dev/null)"
if [ -z "${HDR}" ]; then
  fail "keine HTTP-Antwort von ${ZABBIX_URL}/"
else
  ok "HTTP-Antwort: $(echo "${HDR}" | head -1 | tr -d '\r')"
  XFO="$(echo "${HDR}" | grep -i '^x-frame-options:' | tr -d '\r')"
  if [ -n "${XFO}" ]; then
    warn "Zabbix sendet: ${XFO}"
    echo "         Genau deshalb bleibt ein iframe leer. Der Proxy /zabbix/"
    echo "         entfernt diese Kopfzeile - deshalb IMMER ueber /zabbix/"
    echo "         einbinden, nie direkt auf ${HOST}."
  else
    ok "kein X-Frame-Options - direktes Einbetten waere moeglich"
  fi
fi

# --- Schicht 5: API ----------------------------------------------------------
step "5. API-Zugriff (JSON-RPC)"
if [ -n "${TOKEN}" ] && [ "${TOKEN}" != "REPLACE_WITH_ZABBIX_API_TOKEN" ]; then
  # apiinfo.version wird BEWUSST ohne Authorization aufgerufen: Zabbix lehnt
  # diese eine Methode mit Anmeldung ab ("Invalid params"). Sie beweist damit
  # nur, dass die API antwortet - ueber den Token sagt sie nichts.
  RESP="$(curl -sk -m 10 -X POST "${BASE}/api_jsonrpc.php" \
    -H 'Content-Type: application/json-rpc' \
    -d '{"jsonrpc":"2.0","method":"apiinfo.version","params":{},"id":1}' 2>/dev/null)"
  case "${RESP}" in
    *'"result"'*) ok "Zabbix-API antwortet: Version $(echo "${RESP}" | sed -nE 's/.*"result":"([^"]+)".*/\1/p')" ;;
    *'"error"'*)  fail "API-Fehler: ${RESP}" ;;
    "")           fail "keine Antwort von ${BASE}/api_jsonrpc.php" ;;
    *'<!DOCTYPE html'*|*'<html'*)
      fail "Zabbix antwortet mit einer HTML-Seite statt mit JSON."
      echo "         Der Aufruf landet nicht auf api_jsonrpc.php. Fast immer"
      echo "         steht in ZABBIX_URL eine komplette Dashboard-URL statt"
      echo "         der Basis. Richtig ist z. B.:"
      echo "             ZABBIX_URL=http://server.firma.local/zabbix"
      echo "         Danach: ./scripts/render-config.py && ./scripts/update.sh" ;;
    *)            fail "unerwartete Antwort: ${RESP}" ;;
  esac

  RESP2="$(curl -sk -m 10 -X POST "${BASE}/api_jsonrpc.php" \
    -H 'Content-Type: application/json-rpc' \
    -H "Authorization: Bearer ${TOKEN}" \
    -d '{"jsonrpc":"2.0","method":"problem.get","params":{"limit":1},"id":1}' 2>/dev/null)"
  case "${RESP2}" in
    *'"result"'*) ok "Token gueltig, problem.get funktioniert" ;;
    *'No permissions to call'*)
      fail "Token abgelehnt: keine Berechtigung fuer problem.get"
      echo "         Der Token ist gueltig, aber seine ROLLE erlaubt den Aufruf"
      echo "         nicht. In Zabbix pruefen:"
      echo "           Users -> User roles -> <Rolle des Token-Benutzers>"
      echo "             * 'API' auf Enabled"
      echo "             * API methods: 'Allow list' leer lassen (= alle) oder"
      echo "               problem.get, host.get, trigger.get eintragen"
      echo "           Users -> Users -> <Benutzer> -> Permissions:"
      echo "             mindestens Read auf die relevanten Hostgruppen" ;;
    *'"error"'*)  fail "Token abgelehnt: ${RESP2}" ;;
    *'<html'*|*'<!DOCTYPE html'*)
      fail "auch hier HTML statt JSON - siehe Hinweis oben zu ZABBIX_URL." ;;
    *)            fail "problem.get unerwartet: ${RESP2}" ;;
  esac
fi

# --- Schicht 6: unser Proxy --------------------------------------------------
step "6. Reverse-Proxy auf dem Pi"
if [ -f nginx/conf.d/extra/zabbix.conf ]; then
  warn "Alte nginx/conf.d/extra/zabbix.conf gefunden (Vorlage wurde geteilt)."
  echo "         ./scripts/render-config.py entfernt sie automatisch."
fi
if [ -f nginx/conf.d/extra/zabbix-ui.conf ]; then
  ok "zabbix-ui.conf gerendert (Dashboards einbetten)"
else
  fail "zabbix-ui.conf fehlt - ./scripts/render-config.py ausfuehren (braucht nur ZABBIX_URL)"
fi
if [ -f nginx/conf.d/extra/zabbix-api.conf ]; then
  ok "zabbix-api.conf gerendert (Problemliste auf /lage/)"
else
  warn "zabbix-api.conf fehlt - ohne gueltigen ZABBIX_API_TOKEN wird sie"
  echo "         bewusst nicht geschrieben. Dashboards gehen trotzdem."
fi
for f in nginx/conf.d/extra/zabbix-ui.conf nginx/conf.d/extra/zabbix-api.conf; do
  [ -f "$f" ] && grep -q '\${' "$f" && {
    fail "$f enthaelt offene Platzhalter - nginx startet damit nicht."
    echo "         ./scripts/render-config.py erneut ausfuehren."; }
done

SELF="https://127.0.0.1"
CODE="$(curl -sk -m 10 -o /dev/null -w '%{http_code}' "${SELF}/zabbix/" 2>/dev/null)"
case "${CODE}" in
  200|302|301) ok "/zabbix/ antwortet HTTP ${CODE}" ;;
  404) fail "/zabbix/ -> 404. Der Proxy ist nicht geladen (siehe oben), oder"
       echo "         nginx wurde nach dem Rendern nicht neu gestartet." ;;
  500|502|504) fail "/zabbix/ -> ${CODE}."
       if [ "${API}" = "200" ] 2>/dev/null; then :; fi
       echo "         Antwortet /api/zabbix weiter unten mit 200, erreicht nginx"
       echo "         Zabbix sehr wohl - dann liegt es NICHT an DNS, sondern am"
       echo "         Proxy selbst. Letzte Zeilen des Fehlerprotokolls:"
       docker compose logs --tail 5 nginx 2>/dev/null | sed 's/^/           /'
       echo "         Ist Schritt 2 im Container rot UND /api/zabbix ebenfalls"
       echo "         rot, ist die Namensaufloesung die Ursache." ;;
  000) fail "/zabbix/ nicht erreichbar - nginx antwortet nicht."
       echo "         Pruefen:  docker compose ps   und   docker compose logs nginx"
       echo "         Haeufigste Ursache: eine .conf mit offenen Platzhaltern,"
       echo "         dann bricht nginx beim Start mit 'unknown variable' ab." ;;
  *)   warn "/zabbix/ antwortet HTTP ${CODE}" ;;
esac

API="$(curl -sk -m 10 -o /dev/null -w '%{http_code}' -X POST "${SELF}/api/zabbix" \
       -H 'Content-Type: application/json' \
       -d '{"jsonrpc":"2.0","method":"apiinfo.version","params":{},"id":1}' 2>/dev/null)"
[ "${API}" = "200" ] && ok "/api/zabbix antwortet HTTP 200" \
                     || fail "/api/zabbix antwortet HTTP ${API}"

echo
if [ "${FAILED}" -eq 0 ]; then
  echo "${G}Alles gruen.${D} Dashboard einbinden:"
  echo "  https://<pi>/site/?url=%2Fzabbix%2Fzabbix.php%3Faction%3Ddashboard.view%26dashboardid%3D1%26kiosk%3D1&w=1100&title=Zabbix"
  echo "  (dashboardid aus der Zabbix-URL uebernehmen)"
else
  echo "${R}Bei der ERSTEN roten Zeile ansetzen${D} - alles darunter ist Folgefehler."
fi

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
if [ -z "${TOKEN}" ] || [ "${TOKEN}" = "REPLACE_WITH_ZABBIX_API_TOKEN" ]; then
  warn "ZABBIX_API_TOKEN fehlt in config/secrets.env - die Problemliste bleibt leer."
else
  ok "API-Token hinterlegt (${#TOKEN} Zeichen)"
fi

HOST="$(echo "${ZABBIX_URL}" | sed -E 's#^[a-z]+://##; s#[:/].*$##')"
PORT="$(echo "${ZABBIX_URL}" | sed -nE 's#^[a-z]+://[^:/]+:([0-9]+).*$#\1#p')"
[ -z "${PORT}" ] && { case "${ZABBIX_URL}" in https://*) PORT=443;; *) PORT=80;; esac; }
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
    echo "         Ausweg: in docker-compose.yml beim Dienst nginx ergaenzen:"
    echo "             extra_hosts:"
    echo "               - \"${HOST}:<IP-Adresse>\""
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
HDR="$(curl -sk -m 10 -D- -o /dev/null "${ZABBIX_URL}/" 2>/dev/null)"
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
  RESP="$(curl -sk -m 10 -X POST "${ZABBIX_URL}/api_jsonrpc.php" \
    -H 'Content-Type: application/json-rpc' \
    -H "Authorization: Bearer ${TOKEN}" \
    -d '{"jsonrpc":"2.0","method":"apiinfo.version","params":{},"id":1}' 2>/dev/null)"
  case "${RESP}" in
    *'"result"'*) ok "Zabbix-API antwortet: Version $(echo "${RESP}" | sed -nE 's/.*"result":"([^"]+)".*/\1/p')" ;;
    *'"error"'*)  fail "API-Fehler: ${RESP}" ;;
    "")           fail "keine Antwort von ${ZABBIX_URL}/api_jsonrpc.php" ;;
    *)            fail "unerwartete Antwort: ${RESP}" ;;
  esac

  RESP2="$(curl -sk -m 10 -X POST "${ZABBIX_URL}/api_jsonrpc.php" \
    -H 'Content-Type: application/json-rpc' \
    -H "Authorization: Bearer ${TOKEN}" \
    -d '{"jsonrpc":"2.0","method":"problem.get","params":{"limit":1},"id":1}' 2>/dev/null)"
  case "${RESP2}" in
    *'"result"'*) ok "Token gueltig, problem.get funktioniert" ;;
    *'"error"'*)  fail "Token abgelehnt: $(echo "${RESP2}" | sed -nE 's/.*"data":"([^"]*)".*/\1/p')" ;;
    *)            fail "problem.get unerwartet: ${RESP2}" ;;
  esac
fi

# --- Schicht 6: unser Proxy --------------------------------------------------
step "6. Reverse-Proxy auf dem Pi"
if [ -f nginx/conf.d/extra/zabbix.conf ]; then
  ok "nginx/conf.d/extra/zabbix.conf ist gerendert"
  if grep -q '\${' nginx/conf.d/extra/zabbix.conf; then
    fail "Datei enthaelt noch offene Platzhalter - nginx startet damit nicht."
    echo "         ./scripts/render-config.py erneut ausfuehren."
  fi
else
  fail "nginx/conf.d/extra/zabbix.conf fehlt"
  echo "         ./scripts/render-config.py ausfuehren (braucht ZABBIX_URL"
  echo "         UND ZABBIX_API_TOKEN - fehlt einer, wird die Datei bewusst"
  echo "         nicht geschrieben, damit nginx nicht abstuerzt)."
fi

SELF="https://127.0.0.1"
CODE="$(curl -sk -m 10 -o /dev/null -w '%{http_code}' "${SELF}/zabbix/" 2>/dev/null)"
case "${CODE}" in
  200|302|301) ok "/zabbix/ antwortet HTTP ${CODE}" ;;
  404) fail "/zabbix/ -> 404. Der Proxy ist nicht geladen (siehe oben), oder"
       echo "         nginx wurde nach dem Rendern nicht neu gestartet." ;;
  502|504) fail "/zabbix/ -> ${CODE}. nginx erreicht Zabbix nicht - fast immer"
       echo "         die Namensaufloesung im Container (Schritt 2)." ;;
  000) fail "/zabbix/ nicht erreichbar - laeuft nginx?" ;;
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

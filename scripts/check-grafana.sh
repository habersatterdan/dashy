#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Laeuft Grafana auf diesem Pi - und findet es Zabbix?
#
# Der erste Start dauert mehrere Minuten: Grafana laedt dabei die beiden
# Plugins herunter. Genau in dieser Zeit sieht es aus, als sei etwas kaputt.
# Dieses Skript sagt, in welcher Phase es gerade steckt.
#
#   ./scripts/check-grafana.sh
# -----------------------------------------------------------------------------
set -uo pipefail
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
G=$'\e[32m'; R=$'\e[31m'; Y=$'\e[33m'; D=$'\e[0m'
ok(){ echo "  ${G}OK${D}     $*"; }
warn(){ echo "  ${Y}HINWEIS${D} $*"; }
fehler(){ echo "  ${R}FEHLER${D} $*"; }

echo "== 1. Container"
zeile="$(docker compose ps grafana 2>/dev/null | tail -n +2)"
if [ -z "${zeile}" ]; then
  fehler "Der Dienst 'grafana' laeuft nicht."
  echo "         Starten mit:  ./scripts/update.sh"
  exit 1
fi
echo "  ${zeile}"
case "${zeile}" in
  *healthy*)  ok "Container ist gesund" ;;
  *starting*) warn "startet noch - beim ersten Mal dauert das einige Minuten" ;;
  *Up*)       ok "Container laeuft" ;;
  *)          fehler "Container nicht bereit" ;;
esac

echo
echo "== 2. Antwortet Grafana?"
code="$(curl -sk -m 20 -o /dev/null -w '%{http_code}' https://127.0.0.1/grafana/api/health 2>/dev/null)"
if [ "${code}" = "200" ]; then
  ok "https://<pi>/grafana/ antwortet"
else
  fehler "/grafana/api/health -> HTTP ${code}"
  echo "         Letzte Zeilen:"
  docker compose logs --tail 10 grafana 2>/dev/null | sed 's/^/           /'
fi

echo
echo "== 3. Plugins"
for pl in alexanderzobnin-zabbix-app yesoreyeram-infinity-datasource; do
  if docker compose exec -T grafana sh -c "ls /var/lib/grafana/plugins 2>/dev/null" 2>/dev/null | grep -q "${pl}"; then
    ok "${pl}"
  else
    warn "${pl} noch nicht installiert"
    echo "         Wird beim Start heruntergeladen. Bleibt es dabei, fehlt"
    echo "         der Netzzugang zu grafana.com - dann HTTP_PROXY in .env setzen."
  fi
done

echo
echo "== 4. Datenquelle Zabbix"
if [ -f grafana/provisioning/datasources/zabbix.yml ]; then
  ok "zabbix.yml gerendert"
  antwort="$(curl -sk -m 20 https://127.0.0.1/grafana/api/datasources 2>/dev/null)"
  case "${antwort}" in
    *zabbix*) ok "Grafana kennt die Datenquelle" ;;
    *)        warn "Grafana hat sie noch nicht eingelesen - nach dem Rendern"
              echo "         muss der Container neu erzeugt werden: ./scripts/update.sh" ;;
  esac
else
  fehler "grafana/provisioning/datasources/zabbix.yml fehlt."
  echo "         Sie wird bewusst nur geschrieben, wenn ZABBIX_URL UND"
  echo "         ZABBIX_API_TOKEN gesetzt sind - eine Datenquelle ohne Zugang"
  echo "         wuerde bei jedem Panel einen Fehler werfen."
  echo "         Pruefen:  grep ZABBIX config/endpoints.env config/secrets.env"
fi

echo
echo "== 5. Dashboards"
n="$(ls grafana/dashboards/*.json 2>/dev/null | wc -l | tr -d ' ')"
[ "${n}" -gt 0 ] && ok "${n} Dashboard-Dateien im Repo" \
  || { fehler "keine Dashboards - ./scripts/build-dashboards.py ausfuehren"; }

echo
echo "Aufrufen:"
echo "  Wand    : https://$(hostname)/grafana/d/noc-lagebild/?kiosk"
echo "  Bedienen: https://$(hostname)/grafana/  (admin + GRAFANA_ADMIN_PASSWORD aus .env)"

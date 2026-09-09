#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Prueft jede Feed-Quelle - und zwar zweistufig:
#
#   1. ueber den Proxy   (/feeds/<slug>)   -> was die Wand tatsaechlich sieht
#   2. direkt zur Quelle (die Original-URL) -> wo der Fehler herkommt
#
# Warum beides: Antwortet der Proxy mit einem Fehler, sagt das noch nicht, ob
# nginx falsch konfiguriert ist oder der Anbieter die Adresse geaendert hat.
# Anbieter tun das regelmaessig - Microsoft hat status.office365.com und
# azureedge.net stillgelegt.
#
#   ./scripts/check-feeds.sh
#   ./scripts/check-feeds.sh --kandidaten    # bekannte Alternativadressen testen
# -----------------------------------------------------------------------------
set -uo pipefail
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

G=$'\e[32m'; R=$'\e[31m'; Y=$'\e[33m'; D=$'\e[0m'
BASE="https://127.0.0.1"

# Beurteilt eine Antwort: gueltiges XML mit Eintraegen?
beurteile() {
  local body="$1"
  case "${body}" in
    '')                      echo "leer" ;;
    *'<item'*|*'<entry'*)    echo "ok" ;;
    *'<rss'*|*'<feed'*)      echo "xml-ohne-eintraege" ;;
    *'<!DOCTYPE html'*|*'<html'*) echo "html" ;;
    *'{'*)                   echo "json" ;;
    *)                       echo "unbekannt" ;;
  esac
}

pruefe_proxy() {
  local slug="$1"
  local code body
  code="$(curl -sk -m 20 -o /dev/null -w '%{http_code}' "${BASE}/feeds/${slug}" 2>/dev/null)"
  body="$(curl -sk -m 20 "${BASE}/feeds/${slug}" 2>/dev/null | head -c 4000)"
  local art; art="$(beurteile "${body}")"
  case "${code}:${art}" in
    200:ok)  echo "  ${G}OK${D}     /feeds/${slug}  ($(echo "${body}" | grep -o '<item\|<entry' | wc -l | tr -d ' ') Eintraege im Anfang)" ;;
    200:xml-ohne-eintraege)
      echo "  ${Y}LEER${D}   /feeds/${slug}  gueltiges XML, aber keine Eintraege" ;;
    200:html)
      echo "  ${R}FEHLER${D} /feeds/${slug}  HTML statt Feed - Adresse veraltet?"
      echo "         $(echo "${body}" | tr -d '\n' | head -c 120)" ;;
    200:*)
      echo "  ${R}FEHLER${D} /feeds/${slug}  kein Feed (${art})"
      echo "         $(echo "${body}" | tr -d '\n' | head -c 120)" ;;
    404:*) echo "  ${R}FEHLER${D} /feeds/${slug}  404 - Route nicht vorhanden."
           echo "         Fest eingebaut sind: heise-alerts, heise-security, bsi, cisa, cisco, kev."
           echo "         Alles andere braucht FEEDn_SLUG/FEEDn_URL in config/endpoints.env." ;;
    50*:*) echo "  ${R}FEHLER${D} /feeds/${slug}  HTTP ${code} - nginx erreicht die Quelle nicht"
           echo "         (DNS im Container? Proxy des Firmennetzes?)" ;;
    000:*) echo "  ${R}FEHLER${D} /feeds/${slug}  keine Antwort - laeuft nginx?" ;;
    *)     echo "  ${R}FEHLER${D} /feeds/${slug}  HTTP ${code}" ;;
  esac
}

pruefe_direkt() {
  local name="$1" url="$2"
  local code body
  code="$(curl -s -m 20 -o /dev/null -w '%{http_code}' -A 'NOCSignage/1.0' "${url}" 2>/dev/null)"
  body="$(curl -s -m 20 -A 'NOCSignage/1.0' "${url}" 2>/dev/null | head -c 2000)"
  local art; art="$(beurteile "${body}")"
  if [ "${code}" = "200" ] && [ "${art}" = "ok" ]; then
    echo "  ${G}OK${D}     ${name}"
    echo "         ${url}"
  else
    echo "  ${R}--${D}     ${name}  (HTTP ${code}, ${art})"
    echo "         ${url}"
  fi
}

echo "== Feeds ueber den Proxy (das sieht die Wand)"
for slug in heise-alerts heise-security bsi cisa cisco kev; do pruefe_proxy "${slug}"; done
if [ -f config/endpoints.env ]; then
  for n in 1 2 3 4 5 6; do
    slug="$(grep -E "^FEED${n}_SLUG=" config/endpoints.env 2>/dev/null | cut -d= -f2- | tr -d '"')"
    [ -n "${slug}" ] && pruefe_proxy "${slug}"
  done
fi

echo
echo "== Direkt zur Quelle (zeigt, ob die Adresse noch stimmt)"
if [ -f config/endpoints.env ]; then
  for n in 1 2 3 4 5 6; do
    slug="$(grep -E "^FEED${n}_SLUG=" config/endpoints.env 2>/dev/null | cut -d= -f2- | tr -d '"')"
    url="$(grep -E "^FEED${n}_URL="  config/endpoints.env 2>/dev/null | cut -d= -f2- | tr -d '"')"
    [ -n "${url}" ] && pruefe_direkt "FEED${n} (${slug})" "${url}"
  done
else
  echo "  (config/endpoints.env fehlt)"
fi

if [ "${1:-}" = "--kandidaten" ]; then
  echo
  echo "== Alternativadressen testen"
  echo "   Anbieter aendern Feed-Adressen regelmaessig. Was hier gruen ist,"
  echo "   gehoert als FEEDn_URL in config/endpoints.env."
  echo
  echo "  -- Microsoft 365 --"
  pruefe_direkt "status.cloud.microsoft" "https://status.cloud.microsoft/api/feed/rss"
  pruefe_direkt "admin.microsoft (Roadmap)" "https://www.microsoft.com/releasecommunications/api/v2/m365/rss"
  echo "  -- Microsoft Azure --"
  pruefe_direkt "azure.status.microsoft" "https://azure.status.microsoft/en-us/status/feed/"
  pruefe_direkt "azure.microsoft.com" "https://azure.microsoft.com/en-us/status/feed/"
  echo "  -- Weitere fuer euren Stack --"
  pruefe_direkt "Fortinet PSIRT" "https://filestore.fortinet.com/fortiguard/rss/ir.xml"
  pruefe_direkt "VMware/Broadcom" "https://support.broadcom.com/security-advisory/rss"
  pruefe_direkt "Veeam" "https://www.veeam.com/rss/kb.xml"
  pruefe_direkt "GitHub Status" "https://www.githubstatus.com/history.rss"
  pruefe_direkt "Atlassian Status" "https://status.atlassian.com/history.rss"
  pruefe_direkt "heise Security" "https://www.heise.de/security/rss/news-atom.xml"
  pruefe_direkt "Golem Security" "https://rss.golem.de/rss.php?tp=sec&feed=RSS2.0"
fi

echo
echo "Gruene Quellen in config/sources.txt eintragen (Name | slug),"
echo "dann: docker compose restart nginx"

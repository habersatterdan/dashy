#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Alte und tote Eintraege aus config/ finden - und auf Wunsch stilllegen.
#
# WARUM ES DAS GIBT: Die Dateien unter config/ sind gitignored. Genau deshalb
# ueberleben sie jedes Update - aber eben auch die Beispielwerte, mit denen man
# angefangen hat, und Zeilen fuer Dinge, die es laengst nicht mehr gibt. Auf der
# Wand sieht das aus wie ein Ausfall. "example.local nicht erreichbar" ist kein
# Fehler des Systems, sondern eine Karteileiche.
#
# GRUNDREGEL: Nichts wird geloescht. Beanstandete Zeilen werden mit # davor
# stillgelegt und die Datei vorher nach <name>.bak gesichert. Was hier
# faelschlich anschlaegt, holt man mit einem Handgriff zurueck.
#
#   ./scripts/aufraeumen.sh              # nur zeigen, nichts aendern
#   ./scripts/aufraeumen.sh --anwenden   # gefundene Zeilen stilllegen
# -----------------------------------------------------------------------------
set -uo pipefail
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

G=$'\e[32m'; R=$'\e[31m'; Y=$'\e[33m'; B=$'\e[1m'; D=$'\e[0m'
ok(){   echo "  ${G}OK${D}      $*"; }
fund(){ echo "  ${Y}FUND${D}    $*"; }
info(){ echo "          $*"; }

ANWENDEN=0
[ "${1:-}" = "--anwenden" ] && ANWENDEN=1

FUNDE=0

# Eine Zeile stilllegen: Muster in Datei, mit Sicherung und Beleg.
stilllegen(){
  local datei="$1" muster="$2" grund="$3" n
  [ -f "${datei}" ] || return 0
  # ^ verankern: ohne das trifft das Muster auch Zeilen, die laengst mit #
  # stillgelegt sind - und meldet Funde, die keine sind.
  # KEIN "|| echo 0": grep -c gibt bei null Treffern bereits "0" aus UND
  # liefert Exitcode 1 - der Zusatz haengte eine zweite Null an, und "0\n0"
  # ist keine Zahl. Darum leer abfangen statt den Exitcode zu behandeln.
  n="$(grep -cE "^${muster}" "${datei}" 2>/dev/null)"; n="${n:-0}"
  [ "${n}" = "0" ] && return 0
  FUNDE=$((FUNDE + n))
  fund "${datei}: ${n} Zeile(n) - ${grund}"
  grep -nE "^${muster}" "${datei}" | head -6 | sed 's/^/            /'
  [ "${n}" -gt 6 ] && info "  ... und $((n - 6)) weitere"
  if [ "${ANWENDEN}" = "1" ]; then
    cp "${datei}" "${datei}.bak"
    sed -i -E "s|^(${muster})|# stillgelegt: ${grund}\n#\1|" "${datei}" 2>/dev/null \
      || sed -i -E "s|^(${muster})|#\1|" "${datei}"
    ok "stillgelegt (Sicherung: ${datei}.bak)"
  fi
}

echo "${B}Aufraeumen - was in config/ nichts mehr zu suchen hat${D}"
[ "${ANWENDEN}" = "1" ] && echo "  Modus: ANWENDEN - Zeilen werden stillgelegt" \
                        || echo "  Modus: nur zeigen. Zum Anwenden: ./scripts/aufraeumen.sh --anwenden"
echo

# --- 1. Beispielziele der Sonde ----------------------------------------------
echo "${B}1. Sonde (config/probes.txt)${D}"
if [ -f config/probes.txt ]; then
  stilllegen config/probes.txt '[^#]*example\.local' \
    "Beispielziel aus der Vorlage, diesen Rechner gibt es nicht"
  [ "${FUNDE}" = "0" ] && ok "keine Beispielziele"
else
  ok "config/probes.txt nicht angelegt - die Sonde misst nichts"
fi

# --- 2. Adressen, die noch auf example.local zeigen ---------------------------
echo
echo "${B}2. Adressen (config/endpoints.env)${D}"
# Hier NICHT stilllegen: ein leerer _URL-Schluessel ist etwas anderes als ein
# fehlender. Der Renderer laesst den Platz dann bewusst weg. Also nur melden.
if [ -f config/endpoints.env ]; then
  n="$(grep -cE '^[A-Z0-9_]+_URL=.*example\.(local|com)' config/endpoints.env 2>/dev/null)"; n="${n:-0}"
  if [ "${n}" != "0" ]; then
    FUNDE=$((FUNDE + n))
    fund "config/endpoints.env: ${n} Adresse(n) zeigen noch auf example.local"
    grep -nE '^[A-Z0-9_]+_URL=.*example\.(local|com)' config/endpoints.env \
      | head -8 | sed 's/^/            /'
    info "Diese werden NICHT automatisch geaendert: ein leerer Wert bedeutet"
    info "'diesen Platz weglassen' und ist eine gueltige Entscheidung."
    info "Entweder echte Adresse eintragen oder den Wert leeren."
  else
    ok "keine Beispieladressen"
  fi
else
  ok "config/endpoints.env nicht angelegt"
fi

# --- 3. Wandseiten, die nicht laden -------------------------------------------
echo
echo "${B}3. Wandseiten (config/pages.txt)${D}"
if [ -f config/pages.txt ]; then
  tot=0
  while IFS='|' read -r name pfad rest; do
    name="$(echo "${name}" | sed 's/[[:space:]]*$//')"
    pfad="$(echo "${pfad}" | tr -d '[:space:]')"
    case "${name}" in ''|\#*|@*) continue ;; esac
    [ -z "${pfad}" ] && continue
    code="$(curl -sk -m 12 -o /dev/null -w '%{http_code}' "https://127.0.0.1${pfad}" 2>/dev/null)"
    case "${code}" in
      200|301|302|401|403) : ;;
      *) fund "'${name}' antwortet mit HTTP ${code}: ${pfad}"
         tot=$((tot + 1)); FUNDE=$((FUNDE + 1)) ;;
    esac
  done < <(grep -vE '^\s*(#|$)' config/pages.txt)
  if [ "${tot}" = "0" ]; then
    ok "alle Seiten antworten"
  else
    info "Zeile in config/pages.txt loeschen oder # davorsetzen,"
    info "danach: docker compose restart nginx"
  fi
else
  ok "config/pages.txt nicht angelegt - die Wand nutzt die Rueckfallliste"
fi

# --- 4. Doppelte Seiten -------------------------------------------------------
echo
echo "${B}4. Doppelte Eintraege${D}"
dopp_gesamt=0
for f in config/pages.txt config/gruppen.txt config/news.txt config/sources.txt; do
  [ -f "${f}" ] || continue
  dopp="$(grep -vE '^\s*(#|$)' "${f}" | awk -F'|' '{gsub(/^ +| +$/,"",$2); print $2}' \
          | sort | uniq -d | grep -v '^$' || true)"
  if [ -n "${dopp}" ]; then
    FUNDE=$((FUNDE + 1)); dopp_gesamt=$((dopp_gesamt + 1))
    fund "${f}: doppelt vorhanden"
    echo "${dopp}" | sed 's/^/            /'
  fi
done
# Eigener Zaehler: "${dopp}" haelt nur das Ergebnis der LETZTEN Datei - damit
# waere "nichts doppelt" erschienen, obwohl eine fruehere Datei Funde hatte.
[ "${dopp_gesamt}" = "0" ] && ok "nichts doppelt"

# --- 5. Hostgruppen, die Zabbix nicht kennt -----------------------------------
echo
echo "${B}5. Hostgruppen (config/gruppen.txt)${D}"
if [ -f config/gruppen.txt ] && [ -f nginx/conf.d/extra/zabbix-api.conf ]; then
  antwort="$(curl -sk -m 15 -X POST https://127.0.0.1/api/zabbix \
    -H 'Content-Type: application/json' \
    -d '{"jsonrpc":"2.0","method":"hostgroup.get","params":{"output":["name"]},"id":1}' 2>/dev/null)"
  case "${antwort}" in
    *'"result"'*)
      unbekannt=0
      while IFS='|' read -r anzeige gruppe rest; do
        gruppe="$(echo "${gruppe}" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
        case "${gruppe}" in ''|/*) continue ;; esac   # leer oder Regex: nicht pruefbar
        case "${antwort}" in
          *"\"${gruppe}\""*) : ;;
          *) fund "Zabbix kennt keine Hostgruppe '${gruppe}'"
             unbekannt=$((unbekannt + 1)); FUNDE=$((FUNDE + 1)) ;;
        esac
      done < <(grep -vE '^\s*(#|$)' config/gruppen.txt)
      if [ "${unbekannt}" = "0" ]; then
        ok "alle Hostgruppen gibt es in Zabbix"
      else
        info "Schreibweise pruefen (Zabbix: Data collection -> Host groups)."
        info "Danach: ./scripts/build-dashboards.py"
      fi ;;
    '') info "Zabbix antwortet nicht - Hostgruppen ungeprueft." ;;
    *)  info "Unerwartete Antwort von Zabbix - Hostgruppen ungeprueft:"
        echo "            ${antwort}" | cut -c1-160
        info "Genauer: ./scripts/check-zabbix.sh" ;;
  esac
elif [ ! -f config/gruppen.txt ]; then
  ok "keine eigenen Hostgruppen eingetragen"
else
  # Die Datei ist da, aber ohne API laesst sich nichts pruefen. Das als
  # "keine eingetragen" zu melden waere schlicht falsch.
  info "config/gruppen.txt ist gefuellt, aber die Zabbix-API ist nicht"
  info "eingerichtet - Hostgruppen ungeprueft. Einrichten: siehe README."
fi

# --- 6. Angebundene Anwendungen, die nicht liefern ----------------------------
echo
echo "${B}6. Angebundene Anwendungen (config/connect.ini)${D}"
if [ -f config/connect.ini ] && grep -qE '^\[' config/connect.ini; then
  if docker compose exec -T connect python /app/connect.py --test >/tmp/connect-test.$$ 2>&1; then
    ok "alle Anbindungen liefern einen Wert"
  else
    FUNDE=$((FUNDE + 1))
    fund "mindestens eine Anbindung liefert nichts:"
    grep -E 'FEHLER' /tmp/connect-test.$$ | head -8 | sed 's/^/            /'
    info "Abschnitt in config/connect.ini korrigieren oder 'aktiv = false' setzen."
  fi
  rm -f /tmp/connect-test.$$
else
  ok "keine Anwendung angebunden"
fi

# --- 7. Uebriggebliebene Sicherungen ------------------------------------------
echo
echo "${B}7. Sicherungsdateien${D}"
alt="$(find config . -maxdepth 1 -name '*.bak' -mtime +30 2>/dev/null | head -10)"
if [ -n "${alt}" ]; then
  fund "Sicherungen aelter als 30 Tage:"
  echo "${alt}" | sed 's/^/            /'
  info "Koennen weg, wenn die Aenderung laengst laeuft: rm <datei>"
else
  ok "keine alten Sicherungen"
fi

# --- Fazit --------------------------------------------------------------------
echo
if [ "${FUNDE}" = "0" ]; then
  echo "${G}${B}Nichts zu tun - die Konfiguration ist sauber.${D}"
  exit 0
fi
echo "${Y}${B}${FUNDE} Fund(e).${D}"
if [ "${ANWENDEN}" = "1" ]; then
  echo "Stillgelegt, wo es gefahrlos moeglich war. Jetzt uebernehmen:"
  echo "  ./scripts/update.sh"
  echo "Rueckgaengig: die .bak-Datei danebenlegen (cp config/probes.txt.bak config/probes.txt)"
else
  echo "Nichts geaendert. Stilllegen mit:"
  echo "  ./scripts/aufraeumen.sh --anwenden"
  echo "Punkt 2, 3 und 5 bleiben von Hand - dort steckt eine Entscheidung drin."
fi

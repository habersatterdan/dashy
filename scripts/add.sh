#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Etwas zur Wand hinzufuegen - ohne zu wissen, wo was steht.
#
# WARUM ES DAS GIBT: Eine Zabbix-Seite einzubinden hiess bisher, drei Regeln zu
# kennen (ueber /zabbix/ statt direkt, &kiosk=1 anhaengen, mit guest teilen) und
# die richtige von fuenf Konfigurationsdateien zu treffen. Das kann niemand
# nebenbei. Hier beantwortet man zwei Fragen, das Skript macht den Rest -
# einschliesslich der Pruefung, ob es danach wirklich laedt.
#
#   ./scripts/add.sh                 # fragt alles ab
#   ./scripts/add.sh zabbix          # direkt der passende Abschnitt
#   ./scripts/add.sh website|feed|grafana|liste
# -----------------------------------------------------------------------------
set -uo pipefail
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

G=$'\e[32m'; R=$'\e[31m'; Y=$'\e[33m'; B=$'\e[1m'; D=$'\e[0m'
ok(){ echo "  ${G}OK${D}    $*"; }
warn(){ echo "  ${Y}HINWEIS${D} $*"; }
fehler(){ echo "  ${R}FEHLER${D} $*"; }

frage(){ local p="$1" v=""; read -r -p "  ${p}: " v; echo "${v}"; }

# Datei anlegen, falls sie nur als Vorlage existiert.
sicherstellen(){
  local f="$1"
  [ -f "${f}" ] || { cp "${f}.example" "${f}" 2>/dev/null && ok "${f} aus Vorlage angelegt"; }
}

pruefe_url(){
  local pfad="$1" code
  code="$(curl -sk -m 15 -o /dev/null -w '%{http_code}' "https://127.0.0.1${pfad}" 2>/dev/null)"
  case "${code}" in
    200|301|302) ok "laedt (HTTP ${code})"; return 0 ;;
    404) fehler "404 - die Adresse gibt es nicht."; return 1 ;;
    000) fehler "keine Antwort - laeuft nginx? (docker compose ps)"; return 1 ;;
    *)   warn "HTTP ${code} - bitte im Browser nachsehen."; return 0 ;;
  esac
}

anwenden(){
  echo
  echo "  Uebernehme die Aenderung ..."
  docker compose restart nginx >/dev/null 2>&1 && ok "nginx neu geladen" \
    || warn "nginx-Neustart fehlgeschlagen - von Hand: docker compose restart nginx"
}

# --- Zabbix-Dashboard --------------------------------------------------------
add_zabbix(){
  echo "${B}Zabbix-Dashboard hinzufuegen${D}"
  echo "  Oeffne das Dashboard in Zabbix und kopiere die Adresse aus der"
  echo "  Adresszeile. Sie sieht so aus:"
  echo "    http://zabbix.firma.local/zabbix/zabbix.php?action=dashboard.view&dashboardid=419"
  echo
  local roh name id extra pfad
  roh="$(frage 'Adresse aus Zabbix')"
  [ -z "${roh}" ] && { fehler "Nichts eingegeben."; return 1; }

  id="$(echo "${roh}" | sed -nE 's/.*[?&]dashboardid=([0-9]+).*/\1/p')"
  [ -z "${id}" ] && { fehler "In der Adresse steht keine dashboardid."; return 1; }
  ok "Dashboard-ID ${id} erkannt"

  # Zeitraum uebernehmen, falls angegeben - sonst zeigt Zabbix seine Vorgabe.
  extra="$(echo "${roh}" | grep -oE '[?&]from=[^&]*' | head -1 | tr -d '?&')"
  local bis; bis="$(echo "${roh}" | grep -oE '[?&]to=[^&]*' | head -1 | tr -d '?&')"
  [ -n "${extra}" ] && extra="&${extra}"
  [ -n "${bis}" ]   && extra="${extra}&${bis}"

  name="$(frage 'Name auf der Wand (z. B. Netzwerk)')"
  [ -z "${name}" ] && name="Zabbix ${id}"
  local sek; sek="$(frage 'Standzeit in Sekunden [60]')"; sek="${sek:-60}"

  # Die drei Regeln, an denen es sonst scheitert - hier automatisch:
  #  1. ueber /zabbix/ statt direkt (sonst blockt X-Frame-Options)
  #  2. kiosk=1 (sonst steht Zabbix' Menue mit auf der Wand)
  #  3. guest-Freigabe - die kann nur der Mensch in Zabbix setzen
  pfad="/zabbix/zabbix.php?action=dashboard.view&dashboardid=${id}${extra}&kiosk=1"

  sicherstellen config/pages.txt
  printf '%-17s | %s | %s\n' "${name}" "${pfad}" "${sek}" >> config/pages.txt
  ok "in config/pages.txt eingetragen"
  anwenden
  echo
  echo "  Pruefe ${pfad}"
  if pruefe_url "${pfad}"; then
    local koerper
    koerper="$(curl -sk -m 15 "https://127.0.0.1${pfad}" 2>/dev/null)"
    case "${koerper}" in
      *'You are not logged in'*|*'name="login"'*)
        warn "Zabbix verlangt eine Anmeldung."
        echo "         Das ist der EINE Schritt, den nur ihr in Zabbix machen koennt:"
        echo "           Dashboards -> <euer Dashboard> -> Sharing -> Public"
        echo "         (oder mit dem Benutzer 'guest' teilen)" ;;
      *) ok "Dashboard ist ohne Anmeldung sichtbar" ;;
    esac
  fi
}

# --- Website -----------------------------------------------------------------
add_website(){
  echo "${B}Interne Weboberflaeche hinzufuegen${D} (Grafana, PRTG, CheckMK, Wiki ...)"
  echo "  Die meisten Anwendungen verbieten das Einbetten. Ueber unseren Proxy"
  echo "  laufen sie unter EURER Adresse - dann geht es."
  echo
  local url slug name frei n
  url="$(frage 'Basisadresse (z. B. https://grafana.firma.local)')"
  [ -z "${url}" ] && { fehler "Nichts eingegeben."; return 1; }
  case "${url}" in
    *//*) : ;;
    *) fehler "Bitte mit http:// oder https:// beginnen."; return 1 ;;
  esac
  local host; host="$(echo "${url}" | sed -E 's#^[a-z]+://##; s#[:/].*$##')"
  case "${host}" in
    *.*) : ;;
    *) warn "'${host}' ist ein Kurzname. Im Container loest der meist nicht auf -"
       echo "         besser den vollen Namen (FQDN) verwenden." ;;
  esac

  slug="$(frage 'Kurzname fuer den Pfad (z. B. monitoring)')"
  slug="$(echo "${slug}" | tr 'A-Z' 'a-z' | tr -cd 'a-z0-9-')"
  [ -z "${slug}" ] && { fehler "Kurzname darf nur Buchstaben, Ziffern und - enthalten."; return 1; }
  # Belegte Pfade abfangen: zwei location-Bloecke mit demselben Praefix
  # bringen nginx beim Start zu Fall - und zwar den GANZEN Reverse-Proxy,
  # nicht nur diese eine Seite.
  case " ${slug} " in
    " grafana "|" zabbix "|" lage "|" wall "|" news "|" stoerungen "|" site "|" signage "|" feeds "|" data "|" config "|" admin "|" health "|" shots "|" tiles "|" pages "|" assets ")
      fehler "'${slug}' ist bereits vergeben (eingebaute Seite)."
      echo "         Bitte einen anderen Kurznamen waehlen, z. B. '${slug}-intern'."
      return 1 ;;
  esac
  if grep -qE "^EMBED[0-9]_SLUG=${slug}$" config/endpoints.env 2>/dev/null; then
    fehler "'${slug}' ist schon als Einbettung eingetragen."
    return 1
  fi

  sicherstellen config/endpoints.env
  frei=""
  for n in 1 2 3 4; do
    grep -qE "^EMBED${n}_URL=.+" config/endpoints.env || { frei="${n}"; break; }
  done
  [ -z "${frei}" ] && { fehler "Alle vier Einbett-Plaetze belegt. Einen in config/endpoints.env freimachen."; return 1; }

  # Vorhandene leere Zeilen ersetzen statt doppelt anzuhaengen.
  sed -i "/^EMBED${frei}_SLUG=/d; /^EMBED${frei}_URL=/d" config/endpoints.env
  printf 'EMBED%s_SLUG=%s\nEMBED%s_URL=%s\n' "${frei}" "${slug}" "${frei}" "${url}" >> config/endpoints.env
  ok "als EMBED${frei} in config/endpoints.env eingetragen"

  ./scripts/render-config.py >/dev/null 2>&1 && ok "Proxy erzeugt" || fehler "Rendern fehlgeschlagen"
  anwenden

  name="$(frage "Name auf der Wand [${slug}]")"; name="${name:-${slug}}"
  local sek; sek="$(frage 'Standzeit in Sekunden [45]')"; sek="${sek:-45}"
  sicherstellen config/pages.txt
  printf '%-17s | /%s/ | %s\n' "${name}" "${slug}" "${sek}" >> config/pages.txt
  ok "in config/pages.txt eingetragen"
  echo
  pruefe_url "/${slug}/"
}

# --- RSS-Feed ----------------------------------------------------------------
add_feed(){
  echo "${B}Nachrichtenquelle (RSS/Atom) hinzufuegen${D}"
  local url slug name frei n
  url="$(frage 'Feed-Adresse')"
  [ -z "${url}" ] && { fehler "Nichts eingegeben."; return 1; }

  echo "  Pruefe die Quelle direkt ..."
  local kopf; kopf="$(curl -s -m 20 -A 'NOCSignage/1.0' "${url}" 2>/dev/null | head -c 400)"
  case "${kopf}" in
    *'<item'*|*'<entry'*) ok "gueltiger Feed mit Eintraegen" ;;
    *'<rss'*|*'<feed'*)   warn "gueltiges XML, derzeit ohne Eintraege (bei Statusfeeds normal)" ;;
    '')                   fehler "keine Antwort. Adresse richtig? Proxy im Weg?"; return 1 ;;
    *)                    fehler "kein Feed - die Antwort beginnt mit: ${kopf:0:60}"; return 1 ;;
  esac

  slug="$(frage 'Kurzname (z. B. fortinet)')"
  slug="$(echo "${slug}" | tr 'A-Z' 'a-z' | tr -cd 'a-z0-9-')"
  [ -z "${slug}" ] && { fehler "Kurzname fehlt."; return 1; }

  sicherstellen config/endpoints.env
  frei=""
  for n in 1 2 3 4 5 6; do
    grep -qE "^FEED${n}_URL=.+" config/endpoints.env || { frei="${n}"; break; }
  done
  [ -z "${frei}" ] && { fehler "Alle sechs Feed-Plaetze belegt."; return 1; }
  sed -i "/^FEED${frei}_SLUG=/d; /^FEED${frei}_URL=/d" config/endpoints.env
  printf 'FEED%s_SLUG=%s\nFEED%s_URL=%s\n' "${frei}" "${slug}" "${frei}" "${url}" >> config/endpoints.env
  ok "als FEED${frei} eingetragen"

  ./scripts/render-config.py >/dev/null 2>&1 && ok "Proxy erzeugt"
  anwenden

  name="$(frage "Ueberschrift auf der Wand [${slug}]")"; name="${name:-${slug}}"
  echo "  Wo soll die Quelle erscheinen?"
  echo "    1) Nachrichtenwand /news/   (eigene Spalte)"
  echo "    2) Anbieterstatus /stoerungen/ (eigene Karte)"
  echo "    3) beides"
  local wahl; wahl="$(frage 'Auswahl [1]')"; wahl="${wahl:-1}"
  case "${wahl}" in
    1|3) sicherstellen config/news.txt
         printf '%-15s | %s\n' "${name}" "${slug}" >> config/news.txt
         ok "in config/news.txt eingetragen" ;;
  esac
  case "${wahl}" in
    2|3) sicherstellen config/sources.txt
         printf '%-17s | %s\n' "${name}" "${slug}" >> config/sources.txt
         ok "in config/sources.txt eingetragen" ;;
  esac
  anwenden
  pruefe_url "/feeds/${slug}"
}

# --- Grafana-Dashboard -------------------------------------------------------
add_grafana(){
  echo "${B}Grafana-Dashboard hinzufuegen${D}"
  echo "  Oeffne das Dashboard unter https://<pi>/grafana/ und kopiere die Adresse."
  echo
  local roh uid name
  roh="$(frage 'Adresse aus Grafana')"
  uid="$(echo "${roh}" | sed -nE 's#.*/d/([A-Za-z0-9_-]+).*#\1#p')"
  [ -z "${uid}" ] && { fehler "Keine Dashboard-Kennung (/d/<uid>/) gefunden."; return 1; }
  ok "Dashboard ${uid} erkannt"
  name="$(frage 'Name auf der Wand')"; name="${name:-Grafana ${uid}}"
  local sek; sek="$(frage 'Standzeit in Sekunden [60]')"; sek="${sek:-60}"
  local pfad="/grafana/d/${uid}/?kiosk&refresh=30s"
  sicherstellen config/pages.txt
  printf '%-17s | %s | %s\n' "${name}" "${pfad}" "${sek}" >> config/pages.txt
  ok "in config/pages.txt eingetragen"
  anwenden
  pruefe_url "${pfad}"
}

# --- Uebersicht --------------------------------------------------------------
zeige_liste(){
  echo "${B}Was die Wand derzeit zeigt${D}  (config/pages.txt)"
  if [ -f config/pages.txt ]; then
    grep -vE '^\s*(#|$)' config/pages.txt | nl -w3 -s'. ' | sed 's/^/  /'
  else
    warn "config/pages.txt fehlt - mit ./scripts/add.sh anlegen."
  fi
  echo
  echo "${B}Nachrichtenquellen${D}  (config/news.txt)"
  [ -f config/news.txt ] && grep -vE '^\s*(#|$)' config/news.txt | sed 's/^/  /' \
    || echo "  (nicht angelegt)"
  echo
  echo "  Entfernen: Zeile in der Datei loeschen oder mit # davor auskommentieren,"
  echo "  danach: docker compose restart nginx"
}

# --- Einstieg ----------------------------------------------------------------
art="${1:-}"
if [ -z "${art}" ]; then
  echo "${B}Was moechtest du zur Wand hinzufuegen?${D}"
  echo "  1) Zabbix-Dashboard"
  echo "  2) Interne Weboberflaeche (Grafana, PRTG, CheckMK, Wiki ...)"
  echo "  3) Nachrichtenquelle (RSS/Atom)"
  echo "  4) Grafana-Dashboard von diesem Pi"
  echo "  5) Nur anzeigen, was schon drin ist"
  echo
  case "$(frage 'Auswahl')" in
    1) art=zabbix ;; 2) art=website ;; 3) art=feed ;;
    4) art=grafana ;; 5) art=liste ;;
    *) fehler "Unbekannte Auswahl."; exit 1 ;;
  esac
fi

echo
case "${art}" in
  zabbix)  add_zabbix ;;
  website) add_website ;;
  feed)    add_feed ;;
  grafana) add_grafana ;;
  liste)   zeige_liste; exit 0 ;;
  *) fehler "Unbekannt: ${art}"; echo "  zabbix | website | feed | grafana | liste"; exit 1 ;;
esac

echo
echo "${G}Fertig.${D} Ansehen:  https://$(hostname)/signage/"
echo "Alles pruefen:  ./scripts/check-wall.sh"

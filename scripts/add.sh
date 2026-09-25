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
#   ./scripts/add.sh website|feed|grafana|gruppe|anwendung|liste
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

# --- Aus dem Katalog waehlen -------------------------------------------------
# WARUM: "Welche Quellen gibt es denn Sinnvolles?" ist die Frage, an der die
# meisten haengenbleiben - nicht an der Bedienung. Der Katalog beantwortet sie
# mit einer Liste, aus der man eine Nummer tippt. Geprueft wird trotzdem: eine
# umgezogene Feed-Adresse faellt hier auf, nicht auf der Wand.
add_katalog(){
  echo "${B}Aus dem Katalog waehlen${D}"
  sicherstellen config/katalog.txt
  if [ ! -f config/katalog.txt ]; then
    fehler "config/katalog.txt fehlt und liess sich nicht anlegen."
    return 1
  fi

  # Einlesen in Felder. Kommentare und unvollstaendige Zeilen fallen raus.
  local -a k_art k_name k_slug k_url k_bem
  local n=0 zeile
  while IFS='|' read -r art name slug url bem; do
    art="$(echo "${art}"  | tr -d '[:space:]')"
    case "${art}" in ''|\#*) continue ;; esac
    name="$(echo "${name}" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
    slug="$(echo "${slug}" | tr -d '[:space:]')"
    url="$(echo  "${url}"  | tr -d '[:space:]')"
    bem="$(echo  "${bem}"  | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
    [ -z "${url}" ] && continue
    n=$((n + 1))
    k_art[n]="${art}"; k_name[n]="${name}"; k_slug[n]="${slug}"
    k_url[n]="${url}"; k_bem[n]="${bem}"
  done < config/katalog.txt

  if [ "${n}" = "0" ]; then
    fehler "Der Katalog enthaelt keine gueltige Zeile."
    echo "         Aufbau:  Art | Anzeigename | Kurzname | Adresse | Bemerkung"
    return 1
  fi

  local i schon
  for i in $(seq 1 "${n}"); do
    # Schon eingetragen? Dann nicht zum zweiten Mal anbieten.
    schon=""
    grep -qE "^FEED[0-9]_SLUG=${k_slug[i]}$|^EMBED[0-9]_SLUG=${k_slug[i]}$" \
      config/endpoints.env 2>/dev/null && schon=" ${G}[bereits drin]${D}"
    printf "  %2d) %-18s %s%s\n" "${i}" "${k_name[i]}" "${k_bem[i]}" "${schon}"
  done
  echo
  echo "  Mehrere gehen: 1 3 7"
  local wahl; wahl="$(frage 'Nummer(n)')"
  [ -z "${wahl}" ] && { warn "Nichts gewaehlt."; return 0; }

  local nr gewaehlt=0
  for nr in ${wahl}; do
    case "${nr}" in
      ''|*[!0-9]*) fehler "'${nr}' ist keine Nummer."; continue ;;
    esac
    if [ "${nr}" -lt 1 ] || [ "${nr}" -gt "${n}" ]; then
      fehler "${nr} steht nicht im Katalog (1 bis ${n})."; continue
    fi
    echo
    echo "  ${B}${k_name[nr]}${D}"
    if [ "${k_art[nr]}" = "website" ]; then
      katalog_website "${k_name[nr]}" "${k_slug[nr]}" "${k_url[nr]}" && gewaehlt=$((gewaehlt+1))
    else
      katalog_feed "${k_name[nr]}" "${k_slug[nr]}" "${k_url[nr]}" && gewaehlt=$((gewaehlt+1))
    fi
  done

  [ "${gewaehlt}" = "0" ] && return 1
  ./scripts/render-config.py >/dev/null 2>&1 && ok "Proxy erzeugt"
  anwenden
  echo
  echo "  ${gewaehlt} Quelle(n) uebernommen. Ansehen:"
  echo "    Nachrichten   https://$(hostname)/news/"
  echo "    Anbieterstatus https://$(hostname)/stoerungen/"
}

# Eine Feed-Zeile aus dem Katalog eintragen - mit Pruefung vorher.
katalog_feed(){
  local name="$1" slug="$2" url="$3" frei n kopf
  if grep -qE "^FEED[0-9]_SLUG=${slug}$" config/endpoints.env 2>/dev/null; then
    warn "'${slug}' ist bereits eingetragen - uebersprungen."
    return 1
  fi
  echo "    Pruefe die Quelle ..."
  kopf="$(curl -s -m 20 -A 'NOCSignage/1.0' "${url}" 2>/dev/null | head -c 400)"
  case "${kopf}" in
    *'<item'*|*'<entry'*) ok "gueltiger Feed mit Eintraegen" ;;
    *'<rss'*|*'<feed'*)   warn "gueltiges XML, derzeit ohne Eintraege (bei Statusfeeds normal)" ;;
    '') fehler "keine Antwort. Adresse umgezogen, oder der Proxy blockt."
        echo "           ${url}"
        return 1 ;;
    *)  fehler "kein Feed. Die Antwort beginnt mit: ${kopf:0:60}"
        return 1 ;;
  esac

  sicherstellen config/endpoints.env
  frei=""
  for n in 1 2 3 4 5 6; do
    grep -qE "^FEED${n}_URL=.+" config/endpoints.env || { frei="${n}"; break; }
  done
  if [ -z "${frei}" ]; then
    fehler "Alle sechs Feed-Plaetze belegt."
    echo "           Einen in config/endpoints.env freimachen (FEEDn_URL= leeren)."
    return 1
  fi
  sed -i "/^FEED${frei}_SLUG=/d; /^FEED${frei}_URL=/d" config/endpoints.env
  printf 'FEED%s_SLUG=%s\nFEED%s_URL=%s\n' "${frei}" "${slug}" "${frei}" "${url}" >> config/endpoints.env
  ok "als FEED${frei} eingetragen"

  # Sicherheitsmeldungen gehoeren auf /news/, Anbieterstatus auf /stoerungen/.
  # Die Entscheidung nimmt der Katalog dem Nutzer ab - aendern geht jederzeit
  # in config/news.txt bzw. config/sources.txt.
  case "${slug}" in
    bsi|cisa|fortinet|heise-sec|golem-sec|bleeping)
      sicherstellen config/news.txt
      grep -q "| ${slug}$" config/news.txt 2>/dev/null \
        || printf '%-17s | %s\n' "${name}" "${slug}" >> config/news.txt
      ok "auf der Nachrichtenwand /news/" ;;
    *)
      sicherstellen config/sources.txt
      grep -q "| ${slug}$" config/sources.txt 2>/dev/null \
        || printf '%-17s | %s\n' "${name}" "${slug}" >> config/sources.txt
      ok "beim Anbieterstatus /stoerungen/" ;;
  esac
  return 0
}

# Eine Website-Zeile aus dem Katalog einbetten.
katalog_website(){
  local name="$1" slug="$2" url="$3" frei n
  if grep -qE "^EMBED[0-9]_SLUG=${slug}$" config/endpoints.env 2>/dev/null; then
    warn "'${slug}' ist bereits eingebettet - uebersprungen."
    return 1
  fi
  sicherstellen config/endpoints.env
  frei=""
  for n in 1 2 3 4; do
    grep -qE "^EMBED${n}_URL=.+" config/endpoints.env || { frei="${n}"; break; }
  done
  [ -z "${frei}" ] && { fehler "Alle vier Einbett-Plaetze belegt."; return 1; }
  sed -i "/^EMBED${frei}_SLUG=/d; /^EMBED${frei}_URL=/d" config/endpoints.env
  printf 'EMBED%s_SLUG=%s\nEMBED%s_URL=%s\n' "${frei}" "${slug}" "${frei}" "${url}" >> config/endpoints.env
  ok "als EMBED${frei} eingetragen"
  sicherstellen config/pages.txt
  grep -q "| /${slug}/ " config/pages.txt 2>/dev/null \
    || printf '%-17s | /%s/ | 45\n' "${name}" "${slug}" >> config/pages.txt
  ok "in config/pages.txt eingetragen"
  return 0
}

# --- Beliebige Anwendung (REST) ----------------------------------------------
# WARUM: LOGINventory, Jira, ein Ticketsystem - alle koennen JSON. Der
# Universalanschluss macht daraus eine Kachel, ohne dass jemand Code schreibt.
# Der entscheidende Schritt ist der letzte: die Anbindung wird SOFORT getestet.
# Ein falscher Pfad faellt hier auf, nicht drei Tage spaeter auf der Wand.
add_anwendung(){
  echo "${B}Anwendung anbinden (LOGINventory, Jira, Ticketsystem ...)${D}"
  echo
  echo "  Gebraucht wird eine Adresse, die JSON zurueckgibt. Beispiele:"
  echo "    Jira, offene Tickets:"
  echo "      https://jira.firma.de/rest/api/2/search?jql=resolution=Unresolved&maxResults=0"
  echo "    LOGINventory, Geraetezahl:"
  echo "      https://loginv.firma.local/api/odata/Device?\$count=true&\$top=0"
  echo

  local name url auth art var var2 wertpfad listenpfad titel gruppe einheit warn krit link
  name="$(frage 'Kurzname (z. B. jira-offen)')"
  name="$(echo "${name}" | tr 'A-Z' 'a-z' | tr -cd 'a-z0-9-')"
  [ -z "${name}" ] && { fehler "Kurzname fehlt."; return 1; }

  sicherstellen config/connect.ini
  if [ -f config/connect.ini ] && grep -qE "^\[${name}\]" config/connect.ini; then
    fehler "'${name}' gibt es schon in config/connect.ini."
    echo "         Bitte einen anderen Kurznamen waehlen oder den Abschnitt dort loeschen."
    return 1
  fi

  url="$(frage 'Adresse (vollstaendig, mit https://)')"
  [ -z "${url}" ] && { fehler "Adresse fehlt."; return 1; }

  echo
  echo "  Wie meldet sich die Anwendung an?"
  echo "    1) gar nicht (offen im internen Netz)"
  echo "    2) Token / API-Key im Authorization-Header (Jira Cloud, viele REST-APIs)"
  echo "    3) Benutzer und Passwort (LOGINventory, aeltere Systeme)"
  echo "    4) eigener Kopfzeilenname, z. B. X-Api-Key"
  auth=""
  case "$(frage 'Auswahl [1]')" in
    2) var="$(frage 'NAME der Variablen fuer den Token (z. B. JIRA_TOKEN)')"
       auth="bearer:${var}" ;;
    3) var="$(frage 'NAME der Variablen fuer den Benutzer (z. B. LOGINV_USER)')"
       var2="$(frage 'NAME der Variablen fuer das Passwort (z. B. LOGINV_PASS)')"
       auth="basic:${var}:${var2}" ;;
    4) art="$(frage 'Name der Kopfzeile (z. B. X-Api-Key)')"
       var="$(frage 'NAME der Variablen mit dem Wert (z. B. LOGINV_KEY)')"
       auth="header:${art}:${var}" ;;
  esac

  # Der wichtigste Sicherheitspunkt dieses Skripts: in die ini kommt NUR der
  # Name. Der Wert wird hier gleich in secrets.env gelegt, damit niemand
  # in Versuchung kommt, ihn doch in die ini zu schreiben.
  if [ -n "${auth}" ]; then
    sicherstellen config/secrets.env
    local v
    for v in ${var:-} ${var2:-}; do
      case "${v}" in ""|X-*) continue ;; esac
      if grep -qE "^${v}=.+" config/secrets.env 2>/dev/null; then
        ok "${v} steht bereits in config/secrets.env"
      else
        local wert; read -r -s -p "  Wert fuer ${v} (Eingabe bleibt unsichtbar): " wert; echo
        if [ -n "${wert}" ]; then
          sed -i "/^${v}=/d" config/secrets.env
          printf '%s=%s\n' "${v}" "${wert}" >> config/secrets.env
          chmod 600 config/secrets.env 2>/dev/null
          ok "${v} in config/secrets.env hinterlegt (Datei nur fuer dich lesbar)"
        else
          warn "${v} bleibt leer - die Kachel wird fehlschlagen, bis der Wert drin steht."
        fi
      fi
    done
  fi

  echo
  echo "  Soll eine ZAHL oder eine LISTE angezeigt werden?"
  echo "    1) eine Zahl (offene Tickets, Geraetezahl, freier Speicher)"
  echo "    2) eine Liste (die neuesten Tickets, die letzten Meldungen)"
  local formart; formart="$(frage 'Auswahl [1]')"; formart="${formart:-1}"

  echo
  echo "  Jetzt der Pfad zum Wert in der Antwort. Punktschreibweise, z. B.:"
  echo "    total                      -> {\"total\": 47}"
  echo "    @odata.count               -> LOGINventory / OData"
  echo "    len:issues                 -> zaehlt die Eintraege der Liste 'issues'"
  echo "    issues[0].fields.summary   -> erster Eintrag, Feld summary"
  echo "  Unsicher? Adresse einmal im Browser oeffnen und hineinsehen."
  if [ "${formart}" = "2" ]; then
    listenpfad="$(frage 'Pfad zur Liste (z. B. issues)')"
    wertpfad=""
    titel="$(frage 'Pfad zur Ueberschrift je Eintrag (z. B. fields.summary)')"
    link="$(frage 'Pfad zum Zusatztext je Eintrag (z. B. key) [leer]')"
  else
    wertpfad="$(frage 'Pfad zum Wert')"
    listenpfad=""
  fi

  echo
  gruppe="$(frage 'Gruppe auf der Wand [Anwendungen]')"; gruppe="${gruppe:-Anwendungen}"
  local anzeige; anzeige="$(frage "Ueberschrift der Kachel [${name}]")"; anzeige="${anzeige:-${name}}"
  einheit="$(frage 'Einheit [leer]')"
  echo "  Schwellen (leer lassen = nie faerben). Steht der kritische Wert UNTER"
  echo "  dem Warnwert, wird umgekehrt gezaehlt - fuer \"freier Speicher\"."
  warn="$(frage 'Warnung ab')"
  krit="$(frage 'Kritisch ab')"

  {
    printf '\n[%s]\n' "${name}"
    printf 'titel  = %s\n' "${anzeige}"
    printf 'gruppe = %s\n' "${gruppe}"
    printf 'url    = %s\n' "${url}"
    [ -n "${auth}" ]       && printf 'auth   = %s\n' "${auth}"
    [ -n "${listenpfad}" ] && printf 'liste  = %s\n' "${listenpfad}"
    [ -n "${listenpfad}" ] && [ -n "${titel}" ] && printf 'eintrag_titel = %s\n' "${titel}"
    [ -n "${listenpfad}" ] && [ -n "${link}" ]  && printf 'eintrag_text  = %s\n' "${link}"
    [ -n "${wertpfad}" ]   && printf 'wert   = %s\n' "${wertpfad}"
    [ -n "${einheit}" ]    && printf 'einheit = %s\n' "${einheit}"
    [ -n "${warn}" ]       && printf 'warn   = %s\n' "${warn}"
    [ -n "${krit}" ]       && printf 'krit   = %s\n' "${krit}"
  } >> config/connect.ini
  ok "in config/connect.ini eingetragen"

  # Sofort ausprobieren - im Container, damit dieselben Zertifikate und
  # dieselben Zugangsdaten gelten wie im Dauerbetrieb.
  echo
  echo "  Probiere die Anbindung aus ..."
  if docker compose run --rm --no-deps connect python /app/connect.py --test "${name}"; then
    ok "Die Anbindung liefert einen Wert."
  else
    fehler "Die Anbindung liefert noch keinen Wert - siehe Meldung oben."
    echo "         Der Abschnitt [${name}] steht bereits in config/connect.ini;"
    echo "         dort Pfad oder Adresse korrigieren und erneut pruefen mit:"
    echo "           docker compose run --rm --no-deps connect python /app/connect.py --test ${name}"
  fi

  docker compose up -d connect >/dev/null 2>&1 && ok "Universalanschluss laeuft" \
    || warn "Start fehlgeschlagen - von Hand: docker compose up -d connect"

  # Die Seite selbst muss nur einmal in die Rotation.
  sicherstellen config/pages.txt
  if [ -f config/pages.txt ] && ! grep -q '/kennzahlen/' config/pages.txt; then
    printf '%-17s | %-14s | %s\n' "Kennzahlen" "/kennzahlen/" "40" >> config/pages.txt
    ok "Seite /kennzahlen/ in die Rotation aufgenommen"
    anwenden
  fi
  pruefe_url "/kennzahlen/"
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

# --- Eigene Wandseite fuer eine Zabbix-Hostgruppe ----------------------------
add_gruppe(){
  echo "${B}Eigene Wandseite fuer eine Zabbix-Hostgruppe${D}"
  echo "  Daraus entsteht ein fertiges Grafana-Dashboard - Verfuegbarkeit,"
  echo "  Probleme, CPU, Arbeitsspeicher, Speicherplatz und Antwortzeit,"
  echo "  nur fuer diese Gruppe. Kein Klicken in Grafana noetig."
  echo
  local gruppe name sek uid
  gruppe="$(frage 'Name der Hostgruppe genau wie in Zabbix')"
  [ -z "${gruppe}" ] && { fehler "Nichts eingegeben."; return 1; }

  # Gegen Zabbix pruefen, BEVOR wir eine Seite bauen, die leer bliebe.
  if [ -f nginx/conf.d/extra/zabbix-api.conf ]; then
    local antwort
    antwort="$(curl -sk -m 15 -X POST https://127.0.0.1/api/zabbix \
      -H 'Content-Type: application/json' \
      -d "{\"jsonrpc\":\"2.0\",\"method\":\"hostgroup.get\",\"params\":{\"output\":[\"name\"]},\"id\":1}" 2>/dev/null)"
    case "${antwort}" in
      *"\"${gruppe}\""*) ok "Hostgruppe in Zabbix gefunden" ;;
      *'"result"'*)
        warn "Diese Hostgruppe meldet Zabbix nicht."
        echo "         Vorhandene Gruppen:"
        echo "${antwort}" | grep -o '"name":"[^"]*"' | cut -d'"' -f4 | sort | head -15 | sed 's/^/           /'
        local w; w="$(frage 'Trotzdem anlegen? (j/N)')"
        case "${w}" in j|J|y|Y) : ;; *) return 1 ;; esac ;;
      *) # Nicht einordenbar: dann wenigstens zeigen, WAS kam. "Nicht
         # erreichbar" ohne die Antwort ist eine Sackgasse - mit ihr steht
         # die Ursache meist schon da (403 vom Methodenfilter, HTML statt
         # JSON, leere Antwort bei DNS-Problemen).
         if [ -z "${antwort}" ]; then
           warn "Zabbix antwortet nicht (leere Antwort) - lege die Seite ungeprueft an."
         else
           warn "Unerwartete Antwort von Zabbix - lege die Seite ungeprueft an."
           echo "         Es kam zurueck:"
           echo "           ${antwort}" | cut -c1-200
         fi
         echo "         Genauer nachsehen:  ./scripts/check-zabbix.sh" ;;
    esac
  fi

  name="$(frage "Name auf der Wand [${gruppe}]")"; name="${name:-${gruppe}}"
  sek="$(frage 'Standzeit in Sekunden [45]')"; sek="${sek:-45}"

  sicherstellen config/gruppen.txt
  printf '%s | %s | %s\n' "${name}" "${gruppe}" "${sek}" >> config/gruppen.txt
  ok "in config/gruppen.txt eingetragen"

  ./scripts/build-dashboards.py >/dev/null 2>&1 && ok "Dashboard erzeugt" \
    || { fehler "Erzeugen fehlgeschlagen"; return 1; }

  uid="noc-$(echo "${name}" | tr 'A-Z' 'a-z' \
        | sed 's/ä/ae/g; s/ö/oe/g; s/ü/ue/g; s/ß/ss/g' \
        | sed 's/[^a-z0-9]\+/-/g; s/^-//; s/-$//')"
  sicherstellen config/pages.txt
  printf '%-17s | /grafana/d/%s/?kiosk&refresh=30s | %s\n' "${name}" "${uid}" "${sek}" >> config/pages.txt
  ok "in config/pages.txt eingetragen"
  anwenden
  echo
  pruefe_url "/grafana/d/${uid}/"
  echo
  echo "  Grafana liest neue Dashboards innerhalb von 30 Sekunden ein."
  echo "  Bleibt die Seite leer: ./scripts/check-grafana.sh"
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
  echo "${B}Eigene Zabbix-Seiten${D}  (config/gruppen.txt)"
  [ -f config/gruppen.txt ] && grep -vE '^\s*(#|$)' config/gruppen.txt | sed 's/^/  /' \
    || echo "  (keine - anlegen mit ./scripts/add.sh gruppe)"
  echo
  echo "${B}Nachrichtenquellen${D}  (config/news.txt)"
  [ -f config/news.txt ] && grep -vE '^\s*(#|$)' config/news.txt | sed 's/^/  /' \
    || echo "  (nicht angelegt)"
  echo
  echo "${B}Angebundene Anwendungen${D}  (config/connect.ini)"
  if [ -f config/connect.ini ] && grep -qE '^\[' config/connect.ini; then
    grep -E '^\[' config/connect.ini | tr -d '[]' | sed 's/^/  /'
  else
    echo "  (keine - anbinden mit ./scripts/add.sh anwendung)"
  fi
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
  echo "  5) Eigene Wandseite fuer eine Zabbix-Hostgruppe (empfohlen)"
  echo "  6) Beliebige Anwendung mit REST-Schnittstelle (LOGINventory, Jira ...)"
  echo "  7) Aus dem Katalog waehlen (erprobte Quellen, nur Nummer tippen)"
  echo "  8) Nur anzeigen, was schon drin ist"
  echo
  case "$(frage 'Auswahl')" in
    1) art=zabbix ;; 2) art=website ;; 3) art=feed ;;
    4) art=grafana ;; 5) art=gruppe ;; 6) art=anwendung ;;
    7) art=katalog ;; 8) art=liste ;;
    *) fehler "Unbekannte Auswahl."; exit 1 ;;
  esac
fi

echo
case "${art}" in
  zabbix)  add_zabbix ;;
  website) add_website ;;
  feed)    add_feed ;;
  grafana) add_grafana ;;
  gruppe)  add_gruppe ;;
  anwendung|app) add_anwendung ;;
  katalog) add_katalog ;;
  liste)   zeige_liste; exit 0 ;;
  *) fehler "Unbekannt: ${art}"
     echo "  zabbix | website | feed | grafana | gruppe | anwendung | katalog | liste"; exit 1 ;;
esac

echo
echo "${G}Fertig.${D} Ansehen:  https://$(hostname)/signage/"
echo "Alles pruefen:  ./scripts/check-wall.sh"

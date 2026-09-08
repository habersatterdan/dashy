#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Prueft die Wand selbst: Sind alle Seiten erreichbar, die in config/pages.txt
# stehen? Genau das sieht man der laufenden Rotation nicht an - eine kaputte
# Seite huscht nach 30 Sekunden vorbei und ist wieder weg.
#
#   ./scripts/check-wall.sh
# -----------------------------------------------------------------------------
set -uo pipefail
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

G=$'\e[32m'; R=$'\e[31m'; Y=$'\e[33m'; D=$'\e[0m'
BASE="https://127.0.0.1"
FAILED=0

code(){ curl -sk -m 15 -o /dev/null -w '%{http_code}' "$1" 2>/dev/null; }

echo "== Grundgeruest"
for path in /health /signage/ /lage/ /stoerungen/ /wall/ /config/pages.txt /data/probe.json; do
  c="$(code "${BASE}${path}")"
  case "${c}" in
    200) echo "  ${G}OK${D}     ${path}" ;;
    404) echo "  ${R}FEHLER${D} ${path} -> 404"
         case "${path}" in
           /config/pages.txt) echo "         config/pages.txt fehlt. Anlegen mit:"
                              echo "           cp config/pages.txt.example config/pages.txt"
                              echo "           docker compose restart nginx" ;;
           /data/probe.json)  echo "         Die Sonde hat noch nichts geschrieben. Pruefen:"
                              echo "           docker compose logs --tail 20 probe" ;;
         esac
         FAILED=1 ;;
    000) echo "  ${R}FEHLER${D} ${path} -> keine Antwort (laeuft nginx?)"; FAILED=1 ;;
    *)   echo "  ${R}FEHLER${D} ${path} -> HTTP ${c}"; FAILED=1 ;;
  esac
done

echo
echo "== Seiten aus config/pages.txt"
if [ ! -f config/pages.txt ]; then
  echo "  ${Y}HINWEIS${D} config/pages.txt fehlt - die Wand nutzt die eingebaute"
  echo "          Rueckfallliste (Betriebslage, Stoerungen, Sicherheit)."
else
  n=0
  # Format: Name | Adresse | Sekunden   (# ist Kommentar)
  while IFS= read -r line; do
    line="${line%%$'\r'}"
    case "${line}" in ''|\#*) continue ;; esac
    name="$(echo "${line}" | cut -d'|' -f1 | sed 's/[[:space:]]*$//')"
    url="$(echo "${line}"  | cut -d'|' -f2 | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
    [ -z "${url}" ] && continue
    n=$((n+1))
    c="$(code "${BASE}${url}")"
    case "${c}" in
      200) echo "  ${G}OK${D}     ${name}  (${c})" ;;
      301|302) echo "  ${G}OK${D}     ${name}  (${c}, Weiterleitung)" ;;
      404) echo "  ${R}FEHLER${D} ${name} -> 404"
           echo "         ${url}"
           case "${url}" in
             /zabbix/*) echo "         Pruefen: ./scripts/check-zabbix.sh" ;;
             http*)     echo "         Adressen muessen mit / beginnen, nicht mit http://"
                        echo "         Nur ueber den Proxy laeuft die Anwendung same-origin." ;;
             *)         echo "         Tippfehler im Pfad? Oder Proxy nicht gerendert." ;;
           esac
           FAILED=1 ;;
      000) echo "  ${R}FEHLER${D} ${name} -> keine Antwort"; FAILED=1 ;;
      *)   echo "  ${Y}HINWEIS${D} ${name} -> HTTP ${c}"
           echo "         ${url}" ;;
    esac
  done < config/pages.txt
  echo "  ${n} Seite(n) geprueft."
fi

echo
echo "== Zabbix-Dashboards genauer"
if [ -f config/pages.txt ] && grep -q '/zabbix/' config/pages.txt; then
  grep '/zabbix/' config/pages.txt | grep -v '^#' | while IFS= read -r line; do
    url="$(echo "${line}" | cut -d'|' -f2 | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
    name="$(echo "${line}" | cut -d'|' -f1 | sed 's/[[:space:]]*$//')"
    [ -z "${url}" ] && continue
    body="$(curl -sk -m 15 "${BASE}${url}" 2>/dev/null)"
    case "${body}" in
      *'You are not logged in'*|*'name="login"'*)
        echo "  ${R}FEHLER${D} ${name}: Zabbix verlangt Anmeldung."
        echo "         Dashboard mit dem Benutzer 'guest' teilen:"
        echo "         Zabbix -> Dashboards -> <Dashboard> -> Sharing -> Public" ;;
      *) case "${url}" in
           *kiosk=1*) echo "  ${G}OK${D}     ${name}: laedt, kiosk=1 gesetzt" ;;
           *) echo "  ${Y}HINWEIS${D} ${name}: laedt, aber ohne &kiosk=1 -"
              echo "         das Zabbix-Menue steht dann mit auf der Wand." ;;
         esac ;;
    esac
  done
else
  echo "  (keine Zabbix-Zeilen in config/pages.txt)"
fi

echo
if [ "${FAILED}" -eq 0 ]; then
  echo "${G}Wand ist vollstaendig erreichbar.${D}"
  echo "  Aufrufen:  https://$(hostname)/signage/"
else
  echo "${R}Mindestens eine Seite fehlt${D} - siehe oben."
fi

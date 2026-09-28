#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Sicherung dessen, was NICHT wiederherstellbar ist.
#
# WAS HIER DER PUNKT IST: Der halbe Baum liegt im Git und ist mit einem
# "git clone" zurueck. Nicht wiederherstellbar ist genau das, was gitignored
# ist - config/ mit Zugangsdaten, Sondenzielen, Seitenliste und Hostgruppen,
# dazu .env und der private Schluessel des Zertifikats. GENAU DAS gehoert ins
# Archiv. (Eine fruehere Fassung dieses Skripts sicherte alles AUSSER config/ -
# also praktisch nur Dateien, die ohnehin im Git stehen.)
#
# Das Archiv enthaelt Geheimnisse. Es wird deshalb mit 600 angelegt und
# gehoert nicht in eine Dateiablage, die jeder lesen darf.
#
#   ./scripts/backup.sh              # sichern
#   ./scripts/backup.sh --pruefen    # neuestes Archiv anzeigen, nichts schreiben
#   ./scripts/backup.sh --hilfe      # wie man zurueckspielt
# -----------------------------------------------------------------------------
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BACKUP_DIR="${BACKUP_DIR:-${REPO_DIR}/backups}"
KEEP="${KEEP:-14}"

G=$'\e[32m'; R=$'\e[31m'; Y=$'\e[33m'; B=$'\e[1m'; D=$'\e[0m'

neuestes(){ ls -1t "${BACKUP_DIR}"/signage-*.tar.gz 2>/dev/null | head -1; }

if [ "${1:-}" = "--hilfe" ] || [ "${1:-}" = "-h" ]; then
  cat <<'HILFE'
Zuruecksichern - der ganze Ablauf:

  1. Repo neu holen (der versionierte Teil):
       git clone <euer Repo> ~/dashy && cd ~/dashy
       git checkout claude/noc-signage-raspberry-pi-ea7gg2

  2. Archiv daneben legen und auspacken:
       tar -xzf signage-JJJJMMTT-HHMMSS.tar.gz -C ~/dashy

  3. Rechte wiederherstellen und starten:
       chmod 600 ~/dashy/config/secrets.env ~/dashy/nginx/certs/*.key
       cd ~/dashy && ./scripts/update.sh

  Einzelne Datei herausholen, ohne alles zu ueberschreiben:
       tar -xzf signage-*.tar.gz -C /tmp config/probes.txt
       diff /tmp/config/probes.txt ~/dashy/config/probes.txt

  Was steckt drin?
       ./scripts/backup.sh --pruefen
HILFE
  exit 0
fi

if [ "${1:-}" = "--pruefen" ]; then
  A="$(neuestes || true)"
  if [ -z "${A}" ]; then
    echo "${R}Keine Sicherung vorhanden.${D}  Anlegen: ./scripts/backup.sh"
    exit 1
  fi
  echo "${B}Neuestes Archiv:${D} ${A}"
  echo "  Groesse: $(du -h "${A}" | cut -f1)   Rechte: $(stat -c '%a' "${A}")   vom $(stat -c '%y' "${A}" | cut -d. -f1)"
  echo
  echo "${B}Inhalt (die wichtigsten Dateien):${D}"
  tar -tzf "${A}" | grep -E '^config/|^\.env$|\.key$|\.crt$' | sed 's/^/  /' | head -30
  echo
  # Die Probe aufs Exempel: ein Archiv, das man nicht lesen kann, ist keins.
  if tar -tzf "${A}" >/dev/null 2>&1; then
    echo "${G}Archiv ist lesbar.${D}"
  else
    echo "${R}Archiv ist BESCHAEDIGT.${D}"
    exit 1
  fi
  if tar -tzf "${A}" | grep -q '^config/'; then
    echo "${G}config/ ist enthalten - das ist der Teil, den es sonst nirgends gibt.${D}"
  else
    echo "${R}config/ FEHLT im Archiv - die Sicherung ist wertlos.${D}"
    exit 1
  fi
  exit 0
fi

STAMP="$(date +%Y%m%d-%H%M%S)"
ARCHIVE="${BACKUP_DIR}/signage-${STAMP}.tar.gz"
mkdir -p "${BACKUP_DIR}"

# Nur einpacken, was es wirklich gibt - sonst bricht tar ab und es entsteht
# gar keine Sicherung, weil z. B. kiosk/ auf diesem Geraet fehlt.
TEILE=()
for t in config .env nginx/certs docker-compose.yml kiosk; do
  [ -e "${REPO_DIR}/${t}" ] && TEILE+=("${t}")
done
if [ "${#TEILE[@]}" = "0" ]; then
  echo "${R}Nichts zu sichern gefunden - stimmt das Verzeichnis?${D}"
  exit 1
fi
case " ${TEILE[*]} " in
  *" config "*) : ;;
  *) echo "${Y}WARNUNG: config/ fehlt - es gibt nichts Unersetzliches zu sichern.${D}" ;;
esac

# state/ bleibt bewusst draussen: Messdaten bauen sich in Minuten neu auf und
# blaehen das Archiv nur auf. Ebenso shots/ und backups/ selbst.
tar -czf "${ARCHIVE}" -C "${REPO_DIR}" \
  --exclude='*.bak' --exclude='__pycache__' \
  "${TEILE[@]}"

# Enthaelt secrets.env und den privaten Schluessel.
chmod 600 "${ARCHIVE}"

# Nachsehen, ob wirklich drin ist, was drin sein soll. Eine Sicherung, die
# man erst im Ernstfall prueft, ist eine Wette.
if ! tar -tzf "${ARCHIVE}" >/dev/null 2>&1; then
  echo "${R}Archiv liess sich nicht lesen - Sicherung fehlgeschlagen.${D}"
  rm -f "${ARCHIVE}"
  exit 1
fi
N_CONF="$(tar -tzf "${ARCHIVE}" | grep -c '^config/' || true)"

echo "${G}Sicherung angelegt:${D} ${ARCHIVE}"
echo "  $(du -h "${ARCHIVE}" | cut -f1), Rechte 600, ${N_CONF} Datei(en) aus config/"
echo "  Enthaelt Zugangsdaten - nicht in eine offene Ablage kopieren."

# Aufraeumen: nur die neuesten KEEP behalten.
ls -1t "${BACKUP_DIR}"/signage-*.tar.gz 2>/dev/null | tail -n +$((KEEP + 1)) | xargs -r rm -f
ANZ="$(ls -1 "${BACKUP_DIR}"/signage-*.tar.gz 2>/dev/null | wc -l)"
echo "  ${ANZ} Sicherung(en) vorhanden (es werden ${KEEP} behalten)."
echo
echo "Zurueckspielen:  ./scripts/backup.sh --hilfe"

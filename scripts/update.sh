#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Update auf den aktuellen Stand des Branches - der einzig richtige Weg.
#
# Wichtig: 'git pull' allein reicht nicht. Einzelne Dateien (z. B. conf.yml)
# sind als Bind-Mount eingehaengt und haengen an ihrer Inode. Git schreibt sie
# beim Update neu -> der Container saehe weiter den alten Stand. Darum werden
# die Container hier bewusst neu erzeugt.
#
#   ./scripts/update.sh            # aktueller Branch
#   ./scripts/update.sh <branch>   # anderer Branch
# -----------------------------------------------------------------------------
set -euo pipefail
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# --env-ergaenzen: fehlende Schluessel aus .env.example anhaengen, bestehende
# Werte bleiben unberuehrt.
if [ "${1:-}" = "--env-ergaenzen" ]; then
  [ -f .env ] || cp .env.example .env
  cp .env .env.bak
  ergaenzt=0
  while IFS= read -r zeile; do
    case "${zeile}" in ''|\#*) continue ;; esac
    schluessel="${zeile%%=*}"
    if ! grep -qE "^${schluessel}=" .env; then
      echo "${zeile}" >> .env
      echo "  ergaenzt: ${zeile}"
      ergaenzt=$((ergaenzt+1))
    fi
  done < .env.example
  echo "${ergaenzt} Schluessel ergaenzt (Sicherung: .env.bak)."
  exit 0
fi

BRANCH="${1:-$(git rev-parse --abbrev-ref HEAD)}"

echo "==> [1/4] Hole ${BRANCH}"
git fetch origin "${BRANCH}"
git reset --hard "origin/${BRANCH}"

echo "==> [2/4] Rendere Konfiguration und baue Grafana-Dashboards"
python3 ./scripts/render-config.py
python3 ./scripts/build-dashboards.py

# Die Python-Dienste laufen nicht mehr als root (siehe docker-compose.yml).
# Damit sie ihren Zustand schreiben koennen, muss ./state dem Benutzer
# gehoeren, unter dem sie laufen - sonst startet alles, aber nichts wird
# gespeichert, und das faellt erst Tage spaeter auf.
uid="${RUN_UID:-$(id -u)}"; gid="${RUN_GID:-$(id -g)}"
mkdir -p state shots backups
if [ "$(stat -c '%u' state)" != "${uid}" ]; then
  echo "==> Setze Eigentuemer von ./state auf ${uid}:${gid}"
  # Der Fehlschlag darf NICHT durchrutschen: sonst startet alles, nichts wird
  # gespeichert, und es faellt erst Tage spaeter auf. Darum am Ende pruefen,
  # was wirklich dasteht - nicht, ob ein Befehl 0 zurueckgegeben hat.
  sudo chown -R "${uid}:${gid}" state || chown -R "${uid}:${gid}" state || true
  if [ "$(stat -c '%u' state)" != "${uid}" ]; then
    echo
    echo "ABBRUCH: ./state gehoert $(stat -c '%u:%g' state), gebraucht wird ${uid}:${gid}."
    echo "  Von Hand nachholen und update.sh erneut starten:"
    echo "    sudo chown -R ${uid}:${gid} $(pwd)/state"
    echo "  Stimmen RUN_UID/RUN_GID in .env ueberhaupt? Vergleiche mit: id"
    exit 1
  fi
fi

echo "==> [3/4] Erzeuge Container neu (loest das Inode-Problem)"
docker compose up -d --force-recreate

echo "==> [4/4] Status"
docker compose ps

# Ein Container in der Neustartschleife sieht in "docker compose ps" wie eine
# Randnotiz aus - dabei liefert nginx jede einzelne Wandseite aus. Steht er,
# ist alles dunkel. Darum hier ausdruecklich nachsehen, statt es dem Blick auf
# die Tabelle zu ueberlassen.
echo
echo "==> Pruefe, ob nginx wirklich ausliefert"
lage=""
for _ in 1 2 3 4 5 6 7 8 9 10; do
  lage="$(curl -sk -m 5 -o /dev/null -w '%{http_code}' https://127.0.0.1/health 2>/dev/null || true)"
  [ "${lage}" = "200" ] && break
  sleep 3
done
if [ "${lage}" = "200" ]; then
  echo "    nginx liefert aus (HTTP 200 auf /health)"
else
  echo
  echo "ABBRUCH: nginx antwortet nicht (HTTP ${lage:-000}). Die Wand ist dunkel."
  echo "  Die letzten Zeilen aus dem Log - die Ursache steht fast immer darin:"
  echo
  docker compose logs --tail 15 nginx 2>&1 | sed 's/^/    /'
  echo
  echo "  Danach:  ./scripts/status.sh"
  exit 1
fi

# Neue Schalter kommen mit Updates dazu, die bestehende .env kennt sie nicht -
# und ein fehlender Schluessel wirkt wie ein absichtlich gesetzter Vorgabewert.
# Genau daran scheitert sonst z. B. "CVE_DRY_RUN=false" lautlos.
if [ -f .env ]; then
  fehlend=""
  while IFS= read -r zeile; do
    case "${zeile}" in ''|\#*) continue ;; esac
    schluessel="${zeile%%=*}"
    grep -qE "^${schluessel}=" .env || fehlend="${fehlend} ${schluessel}"
  done < .env.example
  if [ -n "${fehlend}" ]; then
    echo
    echo "HINWEIS: In .env fehlen Schluessel aus .env.example:"
    for k in ${fehlend}; do
      echo "    ${k}=$(grep -E "^${k}=" .env.example | cut -d= -f2- | cut -d'#' -f1 | xargs)"
    done
    echo "  Ohne Eintrag gilt der eingebaute Vorgabewert. Uebernehmen mit:"
    echo "    ./scripts/update.sh --env-ergaenzen"
  fi
fi

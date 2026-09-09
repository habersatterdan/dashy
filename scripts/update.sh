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

echo "==> [2/4] Rendere Konfiguration aus config/*.env"
python3 ./scripts/render-config.py

echo "==> [3/4] Erzeuge Container neu (loest das Inode-Problem)"
docker compose up -d --force-recreate

echo "==> [4/4] Status"
docker compose ps

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

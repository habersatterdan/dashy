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

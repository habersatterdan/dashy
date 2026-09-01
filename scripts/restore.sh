#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Restore the signage configuration from a backup archive.
# Usage:  ./scripts/restore.sh backups/signage-YYYYmmdd-HHMMSS.tar.gz
# -----------------------------------------------------------------------------
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ARCHIVE="${1:?Usage: restore.sh <archive.tar.gz>}"

[ -f "${ARCHIVE}" ] || { echo "Archive not found: ${ARCHIVE}"; exit 1; }

echo ">> Stopping stack"
( cd "${REPO_DIR}" && docker compose down )

echo ">> Restoring ${ARCHIVE} into ${REPO_DIR}"
tar -xzf "${ARCHIVE}" -C "${REPO_DIR}"

echo ">> Starting stack"
( cd "${REPO_DIR}" && docker compose up -d )

echo ">> Restore complete."

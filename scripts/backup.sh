#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Nightly backup of the signage configuration (config, certs, env, assets).
# Wired into cron by install.sh at 02:30 daily. Keeps the last 14 archives.
# -----------------------------------------------------------------------------
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BACKUP_DIR="${BACKUP_DIR:-${REPO_DIR}/backups}"
KEEP="${KEEP:-14}"
STAMP="$(date +%Y%m%d-%H%M%S)"
ARCHIVE="${BACKUP_DIR}/signage-${STAMP}.tar.gz"

mkdir -p "${BACKUP_DIR}"

tar -czf "${ARCHIVE}" -C "${REPO_DIR}" \
  docker-compose.yml \
  .env \
  dashy \
  nginx \
  assets \
  kiosk 2>/dev/null

echo "$(date -Is) backup created: ${ARCHIVE}"

# Rotate: keep only the newest ${KEEP} archives.
ls -1t "${BACKUP_DIR}"/signage-*.tar.gz 2>/dev/null | tail -n +$((KEEP + 1)) | xargs -r rm -f

echo "$(date -Is) retention applied (keep ${KEEP})"

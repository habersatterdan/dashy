#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# One-shot installer for the NOC Digital Signage stack on Raspberry Pi OS 64-bit.
# Run from the repository root:  sudo ./scripts/install.sh
# -----------------------------------------------------------------------------
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_DIR}"

echo "==> [1/6] Installing prerequisites (docker, chromium, unclutter, openssl)"
if ! command -v docker >/dev/null 2>&1; then
  curl -fsSL https://get.docker.com | sh
  usermod -aG docker "${SUDO_USER:-pi}" || true
fi
apt-get update -y
apt-get install -y chromium-browser unclutter openssl x11-xserver-utils || \
  apt-get install -y chromium unclutter openssl x11-xserver-utils

echo "==> [2/6] Creating .env from template (edit it afterwards!)"
[ -f .env ] || cp .env.example .env

echo "==> [3/6] Generating self-signed certificate + admin credentials"
[ -f nginx/certs/signage.crt ] || ( cd nginx/certs && ADMIN_USER=admin bash generate-cert.sh "$(hostname).local" )

echo "==> [4/6] Starting the Docker Compose stack"
docker compose pull
docker compose up -d

echo "==> [5/6] Installing systemd services (stack at boot + kiosk)"
sed "s#/home/pi/dashy#${REPO_DIR}#" kiosk/dashy-stack.service > /etc/systemd/system/dashy-stack.service
systemctl daemon-reload
systemctl enable --now dashy-stack.service

USER_HOME="$(getent passwd "${SUDO_USER:-pi}" | cut -d: -f6)"
install -d -o "${SUDO_USER:-pi}" -g "${SUDO_USER:-pi}" "${USER_HOME}/.config/systemd/user"
cp kiosk/dashy-kiosk.service "${USER_HOME}/.config/systemd/user/"
chown "${SUDO_USER:-pi}:${SUDO_USER:-pi}" "${USER_HOME}/.config/systemd/user/dashy-kiosk.service"
loginctl enable-linger "${SUDO_USER:-pi}" || true
su - "${SUDO_USER:-pi}" -c "systemctl --user daemon-reload && systemctl --user enable --now dashy-kiosk.service" || \
  echo "   (Run 'systemctl --user enable --now dashy-kiosk.service' inside the desktop session.)"

echo "==> [6/6] Installing nightly backup cron (02:30)"
CRON_LINE="30 2 * * * ${REPO_DIR}/scripts/backup.sh >> ${REPO_DIR}/backup.log 2>&1"
( crontab -l 2>/dev/null | grep -v 'scripts/backup.sh' ; echo "${CRON_LINE}" ) | crontab -

echo
echo "==> Done. Signage URL:  https://$(hostname).local/signage/"
echo "==> IMPORTANT: edit .env and dashy/*.yml to replace the REPLACE_WITH_* placeholders,"
echo "    then run:  docker compose restart dashy"

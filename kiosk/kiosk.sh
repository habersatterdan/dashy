#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Launch Chromium in full-screen kiosk mode pointing at the signage wrapper.
# Runs under the desktop session (Wayland/labwc or X11) on Raspberry Pi OS.
# Installed as a systemd --user service (see dashy-kiosk.service).
# -----------------------------------------------------------------------------
set -euo pipefail

URL="${SIGNAGE_URL:-https://localhost/signage/}"
# Chromium binary name differs across Raspberry Pi OS releases.
CHROME="$(command -v chromium-browser || command -v chromium)"

# Hide the mouse cursor when idle (X11 only; Wayland handled by cursor:none CSS).
command -v unclutter >/dev/null 2>&1 && unclutter -idle 0 &

# Prevent screen blanking / DPMS power-off.
if [ "${XDG_SESSION_TYPE:-}" = "x11" ]; then
  xset s off; xset -dpms; xset s noblank || true
fi

exec "${CHROME}" \
  --kiosk \
  --start-fullscreen \
  --incognito \
  --noerrdialogs \
  --disable-infobars \
  --disable-session-crashed-bubble \
  --disable-features=TranslateUI \
  --autoplay-policy=no-user-gesture-required \
  --check-for-update-interval=31536000 \
  --disable-pinch \
  --overscroll-history-navigation=0 \
  --ignore-certificate-errors \
  --password-store=basic \
  --app="${URL}"

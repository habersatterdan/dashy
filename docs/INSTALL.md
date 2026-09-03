# Installation Guide

Target: **Raspberry Pi 5 (8 GB), Raspberry Pi OS 64-bit (Bookworm)**.

## 1. Prepare the Pi

1. Flash Raspberry Pi OS 64-bit (with desktop) using Raspberry Pi Imager.
2. Set hostname (e.g. `noc-signage`), enable SSH, configure Wi-Fi/Ethernet.
3. Boot, then update:
   ```bash
   sudo apt update && sudo apt full-upgrade -y && sudo reboot
   ```

## 2. Get the project

```bash
sudo apt install -y git
git clone <this-repo> ~/dashy
cd ~/dashy
```

## 3. Automated install

```bash
sudo ./scripts/install.sh
```

This installs Docker, Chromium, `unclutter` and OpenSSL; creates `.env`;
generates a self-signed certificate and admin password; starts the Compose
stack; installs the **boot** (`dashy-stack`) and **kiosk** (`dashy-kiosk`)
systemd units; and adds the nightly backup cron job.

> The admin password is printed once during certificate generation — save it.

## 4. Configure your endpoints

Edit the placeholders (`REPLACE_WITH_*`, `*.example.local`):

```bash
nano .env                                        # pick DASHY_PROFILE (enterprise|homelab)
nano profiles/$DASHY_PROFILE/conf.yml
nano profiles/$DASHY_PROFILE/pages/*.yml         # e.g. stoerungen.yml/security.yml/updates.yml (enterprise)
docker compose restart dashy
```

## 5. Verify

```bash
docker compose ps                       # all healthy
curl -k https://localhost/health        # -> ok
```

Open **`https://<hostname>.local/signage/`**. The kiosk service opens this
automatically on boot; the four pages rotate every 30 seconds.

## Manual install (without install.sh)

```bash
cp .env.example .env
cd nginx/certs && ADMIN_USER=admin bash generate-cert.sh noc-signage.local && cd ../..
docker compose up -d
# boot service:
sudo cp kiosk/dashy-stack.service /etc/systemd/system/   # edit WorkingDirectory
sudo systemctl enable --now dashy-stack.service
# kiosk service (as the desktop user):
mkdir -p ~/.config/systemd/user && cp kiosk/dashy-kiosk.service ~/.config/systemd/user/
systemctl --user enable --now dashy-kiosk.service
sudo loginctl enable-linger "$USER"
```

## Display device notes

- **TV / HDMI**: kiosk runs directly on the Pi desktop session.
- **Yealink MeetingBoard / Teams Rooms browser**: point the device browser at
  `https://<hostname>.local/signage/`. Accept the self-signed certificate once,
  or deploy a trusted certificate. The rotation/kiosk logic is inside the page,
  so it also works on browsers you cannot launch with kiosk flags.

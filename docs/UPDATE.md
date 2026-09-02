# Update Guide

## Automatic updates (Watchtower)

Watchtower runs in the stack and checks for new container images on a
**nightly schedule (04:00)**, pulls them, recreates containers with a rolling
restart, and prunes old images.

Configured in `docker-compose.yml`:

```yaml
WATCHTOWER_SCHEDULE=0 0 4 * * *   # sec min hour dom mon dow
WATCHTOWER_CLEANUP=true
WATCHTOWER_ROLLING_RESTART=true
```

Change the time by editing `WATCHTOWER_SCHEDULE`, then:

```bash
docker compose up -d watchtower
```

To pin a stable Dashy version instead of `latest`, set e.g.
`image: lissy93/dashy:3.1.0` and let Watchtower keep it patched within that tag.

## Manual update

```bash
cd ~/dashy
docker compose pull          # fetch newest images
docker compose up -d         # recreate changed containers
docker image prune -f        # reclaim space
```

## Updating configuration

Config is mounted read-only from the repo. After editing any YAML:

```bash
docker compose restart dashy
```

## Updating the OS / kiosk

```bash
sudo apt update && sudo apt full-upgrade -y
sudo reboot
```

The `dashy-stack` and `dashy-kiosk` systemd services restart everything on boot.

# Backup & Restore Guide

## What is backed up

`scripts/backup.sh` archives the full deployable configuration:

- `docker-compose.yml`, `.env`
- `dashy/` (conf.yml + pages)
- `nginx/` (config + certificates + `.htpasswd`)
- `assets/` (kiosk wrapper, CSS, tiles)
- `kiosk/` (scripts + systemd units)

Archives are written to `backups/signage-YYYYmmdd-HHMMSS.tar.gz`.

## Automatic nightly backup

`install.sh` installs a cron job that runs **every night at 02:30** and keeps
the **latest 14** archives:

```cron
30 2 * * * /home/pi/dashy/scripts/backup.sh >> /home/pi/dashy/backup.log 2>&1
```

Verify / edit:

```bash
crontab -l
```

Tune retention with the `KEEP` env var (default 14) or destination with
`BACKUP_DIR`.

## Manual backup

```bash
./scripts/backup.sh
```

## Off-box copies

The archive is self-contained — copy it somewhere safe:

```bash
scp backups/signage-*.tar.gz backup-host:/srv/signage-backups/
# or a nightly rsync to a NAS / file share
```

## Restore

```bash
./scripts/restore.sh backups/signage-YYYYmmdd-HHMMSS.tar.gz
```

This stops the stack, extracts the archive over the repo, and brings the stack
back up. On a fresh Pi: install Docker, clone the repo, then run `restore.sh`.

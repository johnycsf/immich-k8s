# immich-k8s

[![Sponsor](https://img.shields.io/badge/Sponsor-%E2%9D%A4-ea4aaa?logo=githubsponsors&logoColor=white)](https://github.com/sponsors/johnycsf)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Issues](https://img.shields.io/badge/issues-welcome-lightgrey.svg)](../../issues/new/choose)

Immich on Kubernetes for homelab beginners — official images, backup-before-update.

![`./manage.sh` control center](docs/manage-demo.gif)

## Install

```bash
git clone https://github.com/johnycsf/immich-k8s.git
cd immich-k8s
chmod +x manage.sh
./manage.sh
```

`./manage.sh` opens a **↑/↓ menu** with a `>` cursor (j/k and Enter also work). It asks for **StorageClass** and **replica count**. Open the URL the script prints and create your admin account.

Uses **Immich’s official GHCR images** (server, machine-learning, Immich Postgres) plus **Valkey** (Redis-compatible cache from Immich’s official install stack). No LinuxServer or unofficial Immich forks.

Docker version: [immich-docker](https://github.com/johnycsf/immich-docker)

## Why this repo (not just another manifest dump)

- **`./manage.sh`** control center — install, update, backup, status/doctor, uninstall
- Interactive colored install with step progress
- Auto-detects your OS and installs missing host tools (`kubectl`, `helm`, …)
- Choose **StorageClass** and **replica count** (re-run anytime to change)
- Safe **`./manage.sh update`** with automatic pre-update backup
- Incremental hardlink **`./manage.sh backup`** + restore
- **Official upstream images only**

## What you need

- A Kubernetes cluster (`kubectl` context already set)
- `sudo` on this machine so `./manage.sh` can install missing tools (kubectl, helm, curl, openssl, rsync, …)
- Disk for PersistentVolumes

Good fit: small k3s/homelab clusters. Keep replicas conservative on RWO volumes.

## StorageClass and replicas

Install prompts for **StorageClass** and **replica count** (with a safe per-app suggestion). Re-run `./manage.sh` later to change those choices.

Non-interactive: `STORAGE_CLASS=longhorn REPLICAS=1 ./manage.sh`.

The library PVC defaults to **100Gi** — edit `deploy.yaml` before install if you need more space.

## Update

```bash
./manage.sh update
```

Runs `./manage.sh backup` first, then reapplies manifests and rolls out new images. Asks how many local backups to keep.

## Backup and restore

Prefer an external drive or NAS (libraries are large; hardlinks need one filesystem):

```bash
./manage.sh backup --dest /mnt/usb/immich-k8s-backups --keep 3
```

Restore (this cluster or a new one after `./manage.sh`):

```bash
./manage.sh backup --restore --from /mnt/usb/immich-k8s-backups
./manage.sh backup --restore --from ./backups
```

Postgres uses a verified logical dump. The photo library is archived from the running pod then stored with incremental rsync hardlinks. SHA256 seals dumps/config; the library uses a fast inventory fingerprint. Restore warns (does not abort) if integrity looks wrong.

## Uninstall

```bash
kubectl delete namespace immich
# PVCs/data are removed with the namespace when using Longhorn reclaim policies as configured
```

Or use **Uninstall** in `./manage.sh`.

## Fix greyed-out or broken library assets

If photos/videos appear greyed out or logs mention missing thumbnails / video metadata:

```bash
chmod +x fix-library/fix-library.sh
./fix-library/fix-library.sh scan
./fix-library/fix-library.sh fix --apply --wait-metadata
```

See [fix-library/README.md](fix-library/README.md). Back up first: `./manage.sh backup --dest ./backups`.

## Credits

This repo packages or configures upstream software. See [CREDITS.md](CREDITS.md) for the main developers and projects this work builds on.

## Disclaimer

This project is provided **as is**. The author is **not responsible** for any loss, damage, data corruption, downtime, security issues, or other consequences from using it. Full text: [DISCLAIMER.md](DISCLAIMER.md).

## Bug reports & contributions

If you hit an error, please [open a GitHub Issue](../../issues/new/choose) and follow [CONTRIBUTING.md](CONTRIBUTING.md). Fixes via Pull Request are welcome. GitHub Issues/PRs are the supported way to report problems—there is no private support channel.

## Backup exports

Local snapshots stay as incremental hardlink trees (fast rollback). Optionally create a compressed offsite copy with `./manage.sh backup --dest ./backups --archive tar.gz|tar.xz|zip` (add `--archive-password` for zip password or age-passphrase on tar). For stronger key-based encryption use `--encrypt` (age). See repo-framework `docs/BACKUP_ENCRYPTION.md`.

## Security

See [SECURITY.md](SECURITY.md) for how to report vulnerabilities.

Sponsorship funds testing and maintenance: [github.com/sponsors/johnycsf](https://github.com/sponsors/johnycsf).

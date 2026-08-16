# immich-k8s

![Repobeats analytics image](https://repobeats.axiom.co/api/embed/5f30bdb914c6fd7b0af52c0e46864ee86df199ee.svg "Repobeats analytics image")

[![Sponsor](https://img.shields.io/badge/Sponsor-%E2%9D%A4-ea4aaa?logo=githubsponsors&logoColor=white)](https://github.com/sponsors/johnycsf)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Issues](https://img.shields.io/badge/issues-welcome-lightgrey.svg)](../../issues/new/choose)

Deploy [Immich](https://immich.app/) on Kubernetes.

Docker version: [immich-docker](https://github.com/johnycsf/immich-docker)

Uses **Immich’s official GHCR images** (server, machine-learning, Immich Postgres) plus **Valkey** (Redis-compatible cache from Immich’s official install stack). No LinuxServer or unofficial Immich forks.

**Immich on Kubernetes for homelab beginners** — official images, StorageClass/replica prompts, safe updates & backups.

> **Choose your path:** [Docker Compose](https://github.com/johnycsf/immich-docker) · **Kubernetes (this repo)**

## Who this is for

**Good fit:** small k3s/homelab clusters where you want Immich without hand-writing a pile of manifests.

**Not for:** large multi-tenant production clusters — keep replicas conservative (RWO volumes) and read the install prompts.

## Why this repo (not just another manifest dump)

- **`./manage.sh`** control center — install, update, backup, status/doctor, uninstall
- Interactive colored install with step progress
- Auto-detects your OS and installs missing host tools (`kubectl`, `helm`, …)
- Choose **StorageClass** and **replica count** (re-run anytime to change)
- Safe **`./manage.sh update`** with automatic pre-update backup
- Incremental hardlink **`./manage.sh backup`** + restore
- **Official upstream images only**

## Support this work

If this stack saved you setup time, please consider sponsoring — it funds:

- Keeping install/update/backup scripts working across common Linux distros
- Testing safe upgrades against **official** upstream images
- Building more beginner-friendly stacks that share the same `./manage.sh` UX

[![Sponsor johnycsf](https://img.shields.io/badge/GitHub%20Sponsors-Donate-ea4aaa?logo=githubsponsors&logoColor=white)](https://github.com/sponsors/johnycsf)

👉 **[github.com/sponsors/johnycsf](https://github.com/sponsors/johnycsf)**

## What you need

- A Kubernetes cluster (`kubectl` context already set)
- `sudo` on this machine so `./manage.sh` can install missing tools (kubectl, helm, curl, openssl, rsync, …)
- Disk for PersistentVolumes

`./manage.sh` is interactive (colors + step progress). It asks for **StorageClass** and **replica count** (with a safe per-app suggestion). Re-run it later to change those choices. Non-interactive: `STORAGE_CLASS=longhorn REPLICAS=1 ./manage.sh`.

## Interactive control center

`./manage.sh` opens a simple **↑/↓ menu** with a `>` cursor (j/k and Enter also work). No extra packages required.

## Install Immich

```bash
git clone https://github.com/johnycsf/immich-k8s.git
cd immich-k8s
chmod +x manage.sh
./manage.sh          # interactive control center
# or: ./manage.sh
```

Open the URL printed by the script and create your admin account.

The library PVC defaults to **100Gi** — edit `deploy.yaml` before install if you need more space.

Liked the install? Star the repo or [sponsor johnycsf](https://github.com/sponsors/johnycsf) so more stacks stay maintained.

## Update

```bash
./manage.sh update
```

Runs `./manage.sh backup` first, then reapplies manifests and rolls out new images. Asks how many local backups to keep.

Restore:

```bash
./manage.sh backup --restore --from ./backups
./manage.sh backup --restore --from /mnt/usb/immich-backups
```

## Disaster recovery

```bash
./manage.sh backup --dest /mnt/usb/immich-k8s-backups --keep 3
./manage.sh backup --restore --from /mnt/usb/immich-k8s-backups
```

Postgres uses a verified logical dump. The photo library is archived from the running pod then stored with incremental rsync hardlinks. SHA256 seals dumps/config; the library uses a fast inventory fingerprint. Restore warns (does not abort) if integrity looks wrong.

## Uninstall

```bash
kubectl delete namespace immich
# PVCs/data are removed with the namespace when using Longhorn reclaim policies as configured
```

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

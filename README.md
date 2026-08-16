# immich-k8s

![Repobeats analytics image](https://repobeats.axiom.co/api/embed/5f30bdb914c6fd7b0af52c0e46864ee86df199ee.svg "Repobeats analytics image")


[![Sponsor](https://img.shields.io/badge/Sponsor-%E2%9D%A4-ea4aaa?logo=githubsponsors&logoColor=white)](https://github.com/sponsors/johnycsf)

Deploy [Immich](https://immich.app/) on Kubernetes.

Docker version: [immich-docker](https://github.com/johnycsf/immich-docker)

Uses **Immich’s official GHCR images** (server, machine-learning, Immich Postgres) plus **Valkey** (Redis-compatible cache from Immich’s official install stack). No LinuxServer or unofficial Immich forks.


## Why this repo (not just another manifest dump)

- **`./manage.sh`** control center — install, update, backup, status/doctor, uninstall
- Interactive colored install with step progress
- Auto-detects your OS and installs missing host tools (`kubectl`, `helm`, …)
- Choose **StorageClass** and **replica count** (re-run anytime to change)
- Safe **`./update.sh`** with automatic pre-update backup
- Incremental hardlink **`./backup.sh`** + restore
- **Official upstream images only**

## What you need

- A Kubernetes cluster (`kubectl` context already set)
- `sudo` on this machine so `./install.sh` can install missing tools (kubectl, helm, curl, openssl, rsync, …)
- Disk for PersistentVolumes

`./install.sh` is interactive (colors + step progress). It asks for **StorageClass** and **replica count** (with a safe per-app suggestion). Re-run it later to change those choices. Non-interactive: `STORAGE_CLASS=longhorn REPLICAS=1 ./install.sh`.



## Install Immich

```bash
git clone https://github.com/johnycsf/immich-k8s.git
cd immich-k8s
chmod +x manage.sh install.sh
./manage.sh          # interactive control center
# or: ./install.sh
```

Open the URL printed by the script and create your admin account.

The library PVC defaults to **100Gi** — edit `deploy.yaml` before install if you need more space.

## Update

```bash
chmod +x update.sh
./update.sh
```

Runs `./backup.sh` first, then reapplies manifests and rolls out new images. Asks how many local backups to keep.

Restore:

```bash
./backup.sh --restore --from ./backups
./backup.sh --restore --from /mnt/usb/immich-backups
```

## Disaster recovery

```bash
chmod +x backup.sh
./backup.sh --dest /mnt/usb/immich-k8s-backups --keep 3
./backup.sh --restore --from /mnt/usb/immich-k8s-backups
```

Postgres uses a verified logical dump. The photo library is archived from the running pod then stored with incremental rsync hardlinks. SHA256 seals dumps/config; the library uses a fast inventory fingerprint. Restore warns (does not abort) if integrity looks wrong.

## Uninstall

```bash
kubectl delete namespace immich
# PVCs/data are removed with the namespace when using Longhorn reclaim policies as configured
```

## Disclaimer

This project is provided **as is**. The author is **not responsible** for any loss, damage, data corruption, downtime, security issues, or other consequences from using it. Full text: [DISCLAIMER.md](DISCLAIMER.md).

## Bug reports & contributions

If you hit an error, please [open a GitHub Issue](../../issues/new/choose) and follow [CONTRIBUTING.md](CONTRIBUTING.md). Fixes via Pull Request are welcome. GitHub Issues/PRs are the supported way to report problems—there is no private support channel.

## Support this work

If these homelab tools save you time, please consider sponsoring:

[![Sponsor johnycsf](https://img.shields.io/badge/GitHub%20Sponsors-Donate-ea4aaa?logo=githubsponsors&logoColor=white)](https://github.com/sponsors/johnycsf)

👉 **[github.com/sponsors/johnycsf](https://github.com/sponsors/johnycsf)** — tips and monthly support keep these beginner-friendly stacks maintained.


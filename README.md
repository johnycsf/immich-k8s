# immich-k8s

![Repobeats analytics image](https://repobeats.axiom.co/api/embed/5f30bdb914c6fd7b0af52c0e46864ee86df199ee.svg "Repobeats analytics image")

Deploy [Immich](https://immich.app/) on Kubernetes.

Docker version: [immich-docker](https://github.com/johnycsf/immich-docker)

Uses **Immich’s official GHCR images** (server, machine-learning, Immich Postgres) plus **Valkey** (Redis-compatible cache from Immich’s official install stack). No LinuxServer or unofficial Immich forks.

## What you need

- A Kubernetes cluster (`kubectl` context already set)
- `sudo` on this machine so `./install.sh` can install missing tools (kubectl, helm, curl, openssl, rsync, …)
- Disk for PersistentVolumes

`./install.sh` is interactive (colors + step progress). It asks for **StorageClass** and **replica count** (with a safe per-app suggestion). Re-run it later to change those choices. Non-interactive: `STORAGE_CLASS=longhorn REPLICAS=1 ./install.sh`.



## Install Immich

```bash
git clone https://github.com/johnycsf/immich-k8s.git
cd immich-k8s
chmod +x install.sh
./install.sh
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

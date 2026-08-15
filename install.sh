#!/usr/bin/env bash
# Install Immich on Kubernetes (Longhorn + official Immich images).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=deps.sh
source "${ROOT}/deps.sh"
ensure_host_deps k8s
ensure_longhorn_storage

PASS="$(openssl rand -base64 36 | tr -d '\n/+=\n' | tr -cd 'A-Za-z0-9' | head -c 32)"

echo "Applying manifests..."
kubectl apply -f "${ROOT}/deploy.yaml"

echo "Writing database Secret..."
kubectl -n immich create secret generic immich-db \
  --from-literal=DB_USERNAME=postgres \
  --from-literal=DB_DATABASE_NAME=immich \
  --from-literal=DB_PASSWORD="${PASS}" \
  --dry-run=client -o yaml | kubectl apply -f -

echo "Rolling out so pods pick up the Secret..."
kubectl -n immich rollout restart deployment/database deployment/immich-server deployment/immich-machine-learning deployment/redis
kubectl -n immich rollout status deployment/database --timeout=300s
kubectl -n immich rollout status deployment/redis --timeout=180s
kubectl -n immich rollout status deployment/immich-server --timeout=300s
kubectl -n immich rollout status deployment/immich-machine-learning --timeout=600s

umask 077
printf '%s\n' "${PASS}" >"${ROOT}/.db-password"
echo "Saved DB password to ${ROOT}/.db-password (keep private)."

echo "Waiting for LoadBalancer / address..."
ADDR=""
for _ in $(seq 1 60); do
  ADDR="$(kubectl -n immich get svc immich -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)"
  [[ -z "${ADDR}" ]] && ADDR="$(kubectl -n immich get svc immich -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)"
  [[ -n "${ADDR}" ]] && break
  sleep 2
done
if [[ -z "${ADDR}" ]]; then
  ADDR="$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null || echo YOUR_NODE_IP)"
fi

cat <<EOF

Immich is installed.

Open:  http://${ADDR}:2283

1) Create your admin account in the browser
2) Install the Immich mobile apps
3) Later: ./update.sh   and   ./backup.sh --dest /path/to/backups

Library PVC default size is 100Gi — edit deploy.yaml before install if you need more.
Postgres password is in: ${ROOT}/.db-password

EOF

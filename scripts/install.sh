#!/usr/bin/env bash
# Install / reconfigure Immich on Kubernetes (interactive).
# Re-run anytime to change StorageClass preference or replica count.
# Does NOT rotate the DB password on re-run if the Secret already exists.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/deps.sh
source "${ROOT}/scripts/deps.sh"

ui_banner "Immich" "Kubernetes · official images · storage + replicas interactive"
ui_steps_init 5

ui_step "Checking host dependencies"
ensure_host_deps k8s

ui_step "StorageClass"
configure_k8s_storage

ui_step "Replica count (immich-server)"
configure_k8s_replicas immich

ALREADY=false
if kubectl -n immich get deploy immich-server >/dev/null 2>&1; then
  ALREADY=true
  ui_info "Existing Immich install found — refreshing manifests/replicas"
fi

ui_step "Applying manifests"
ui_run "kubectl apply" apply_manifest "${ROOT}/deploy.yaml"

if kubectl -n immich get secret immich-db >/dev/null 2>&1 && [[ "${ALREADY}" == true ]]; then
  ui_ok "Keeping existing immich-db Secret"
  if [[ ! -f "${ROOT}/.db-password" ]]; then
    PASS="$(kubectl -n immich get secret immich-db -o jsonpath='{.data.DB_PASSWORD}' 2>/dev/null | base64 -d 2>/dev/null || true)"
    if [[ -n "${PASS}" ]]; then
      umask 077
      printf '%s\n' "${PASS}" >"${ROOT}/.db-password"
      ui_ok "Wrote DB password to ${ROOT}/.db-password"
    fi
  fi
else
  PASS="$(openssl rand -base64 36 | tr -d '\n/+=\n' | tr -cd 'A-Za-z0-9' | head -c 32)"
  kubectl -n immich create secret generic immich-db \
    --from-literal=DB_USERNAME=postgres \
    --from-literal=DB_DATABASE_NAME=immich \
    --from-literal=DB_PASSWORD="${PASS}" \
    --dry-run=client -o yaml | kubectl apply -f -
  umask 077
  printf '%s\n' "${PASS}" >"${ROOT}/.db-password"
  ui_ok "Generated DB password → ${ROOT}/.db-password"
  ui_run "Restart workloads for Secret" kubectl -n immich rollout restart \
    deployment/database deployment/immich-server deployment/immich-machine-learning deployment/redis
fi

ui_step "Scaling and waiting"
apply_saved_replicas immich
ui_run "database" kubectl -n immich rollout status deployment/database --timeout=300s
ui_run "redis" kubectl -n immich rollout status deployment/redis --timeout=180s
ui_run "immich-server" kubectl -n immich rollout status deployment/immich-server --timeout=300s
ui_run "machine-learning" kubectl -n immich rollout status deployment/immich-machine-learning --timeout=600s

ADDR=""
for _ in $(seq 1 30); do
  ADDR="$(kubectl -n immich get svc immich -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)"
  [[ -z "${ADDR}" ]] && ADDR="$(kubectl -n immich get svc immich -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)"
  [[ -n "${ADDR}" ]] && break
  sleep 2
done
if [[ -z "${ADDR}" ]]; then
  ADDR="$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null || echo YOUR_NODE_IP)"
fi

echo
ui_ok "Immich ready (server replicas=${CHOSEN_REPLICAS:-1}, storage=${CHOSEN_STORAGE_CLASS:-})"
ui_info "Open: ${UI_BOLD}http://${ADDR}:2283${UI_RESET}"
ui_info "DB password file: ${ROOT}/.db-password"
ui_info "Re-run ./manage.sh anytime to change replicas or storage preference"

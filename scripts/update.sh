#!/usr/bin/env bash
# Safely update Immich on Kubernetes; pre-update snapshot via backup.sh.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
NS=immich

KEEP_FILE=".backup-keep-count"
DEFAULT_KEEP=3
BACKUP_ROOT="${ROOT}/backups"

need() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Missing required command: $1" >&2
    exit 1
  }
}

print_offsite_tip() {
  cat <<'EOF'

Tip: Immich libraries are large — keep backups/ on big disks or copy off-box.
Restore: ./manage.sh backup --restore --from ./backups
EOF
}

prune_old_backups() {
  local keep="$1"
  mkdir -p "${BACKUP_ROOT}/snapshots"
  mapfile -t dirs < <(ls -1dt "${BACKUP_ROOT}"/snapshots/* 2>/dev/null || true)
  local total="${#dirs[@]}" i
  if (( total > keep )); then
    for (( i = keep; i < total; i++ )); do
      echo "Removing old snapshot: ${dirs[$i]}"
      rm -rf "${dirs[$i]}"
    done
  else
    echo "Backup retention: keeping all ${total} snapshot(s) (limit ${keep})."
  fi
  local newest
  newest="$(ls -1dt "${BACKUP_ROOT}"/snapshots/* 2>/dev/null | head -1 || true)"
  [[ -n "$newest" ]] && ln -sfn "snapshots/$(basename "$newest")" "${BACKUP_ROOT}/latest"
}

ask_backup_retention() {
  local dir="$1"
  [[ -n "$dir" && -e "$dir" ]] || return 0
  if [[ ! -t 0 ]]; then
    local keep="${DEFAULT_KEEP}"
    [[ -f "${KEEP_FILE}" ]] && keep="$(tr -dc '0-9' <"${KEEP_FILE}" || true)"
    [[ -z "${keep}" ]] && keep="${DEFAULT_KEEP}"
    echo "${keep}" >"${KEEP_FILE}"
    prune_old_backups "${keep}"
    print_offsite_tip
    return 0
  fi
  echo
  local reply=""
  read -r -p "Update succeeded. Keep rollback backup at ${dir}? [Y/n] " reply || true
  case "${reply:-Y}" in
    n|N|no|NO) rm -rf "${dir}"; echo "Backup deleted." ;;
    *)
      local default="${DEFAULT_KEEP}" keep=""
      [[ -f "${KEEP_FILE}" ]] && default="$(tr -dc '0-9' <"${KEEP_FILE}" || true)"
      [[ -z "${default}" ]] && default="${DEFAULT_KEEP}"
      read -r -p "How many local backups should we keep on this disk? [${default}] " keep || true
      keep="$(printf '%s' "${keep:-$default}" | tr -dc '0-9')"
      [[ -z "${keep}" || "${keep}" -lt 1 ]] && keep="${default}"
      echo "${keep}" >"${KEEP_FILE}"
      prune_old_backups "${keep}"
      print_offsite_tip
      ;;
  esac
}

create_backup() {
  [[ -x "${ROOT}/scripts/backup.sh" ]] || { echo "Missing backup.sh" >&2; exit 1; }
  local keep="${DEFAULT_KEEP}"
  [[ -f "${KEEP_FILE}" ]] && keep="$(tr -dc '0-9' <"${KEEP_FILE}" || true)"
  [[ -z "${keep}" ]] && keep="${DEFAULT_KEEP}"
  echo "==> Pre-update snapshot via ./manage.sh backup ..."
  "${ROOT}/scripts/backup.sh" --dest "${BACKUP_ROOT}" --keep "${keep}"
  if [[ -L "${BACKUP_ROOT}/latest" ]]; then
    BACKUP_DIR="$(readlink -f "${BACKUP_ROOT}/latest")"
  else
    BACKUP_DIR="$(ls -1dt "${BACKUP_ROOT}"/snapshots/* 2>/dev/null | head -1 || true)"
  fi
  [[ -n "${BACKUP_DIR}" && -d "${BACKUP_DIR}" ]] || { echo "Backup failed." >&2; exit 1; }
}

need kubectl
# shellcheck source=scripts/deps.sh
source "${ROOT}/scripts/deps.sh"
require_storage_class

if ! kubectl -n "$NS" get deploy immich-server >/dev/null 2>&1; then
  echo "Immich is not installed yet. Run ./manage.sh first." >&2
  exit 1
fi

create_backup

echo "==> Applying manifests..."
apply_manifest "${ROOT}/deploy.yaml"
apply_saved_replicas immich
echo "==> Rolling out (picks up newer :v3 / image digests)..."
kubectl -n "$NS" rollout restart deployment/database deployment/redis deployment/immich-server deployment/immich-machine-learning
kubectl -n "$NS" rollout status deployment/database --timeout=300s
kubectl -n "$NS" rollout status deployment/redis --timeout=180s
kubectl -n "$NS" rollout status deployment/immich-server --timeout=300s
kubectl -n "$NS" rollout status deployment/immich-machine-learning --timeout=600s

echo "==> Pruning unused images on this machine when possible..."
if command -v k3s >/dev/null 2>&1; then
  sudo k3s crictl rmi --prune 2>/dev/null || echo "(skipped k3s prune)"
elif command -v docker >/dev/null 2>&1; then
  docker image prune -f
fi

echo
echo "Update finished."
echo "  kubectl -n immich get svc immich"
ask_backup_retention "${BACKUP_DIR}"

#!/usr/bin/env bash
# Immich k8s disaster-recovery backup/restore (incremental library + Postgres dump).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=deps.sh
source "${ROOT}/deps.sh"
cd "$ROOT"
# shellcheck source=backup-encrypt.sh
source "${ROOT}/backup-encrypt.sh"
NS=immich
STACK_ID="immich-k8s"

need() {
  command -v "$1" >/dev/null 2>&1 || { echo "Missing: $1" >&2; exit 1; }
}
need_rsync() {
  command -v rsync >/dev/null 2>&1 || { echo "Missing: rsync" >&2; exit 1; }
}

usage() {
  cat <<'EOF'
Usage:
  ./backup.sh --dest /path/to/backup-root [--keep N] [--include-model-cache] [--encrypt]
  ./backup.sh --restore --from /path/to/backup-root-or-snapshot-or.tar.age
  ./backup.sh --help

  --encrypt / --export-dir / --age-recipient / --age-identity / --passphrase
  SHA256 = integrity; age = optional encrypted offsite export.
EOF
}

MODE=""; DEST=""; FROM=""; KEEP=""; INCLUDE_MODEL_CACHE=0
ENCRYPT="${BACKUP_ENCRYPT:-0}"
EXPORT_DIR="${BACKUP_EXPORT_DIR:-}"
ENCRYPT_PASSPHRASE=0
AGE_RECIPIENTS=()
AGE_IDENTITY="${BACKUP_AGE_IDENTITY:-}"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dest) DEST="$2"; MODE="${MODE:-backup}"; shift 2 ;;
    --from) FROM="$2"; shift 2 ;;
    --restore) MODE="restore"; shift ;;
    --encrypt)
      ENCRYPT=1; shift ;;
    --export-dir)
      [[ $# -ge 2 ]] || { echo "--export-dir needs a path" >&2; exit 1; }
      EXPORT_DIR="$2"; shift 2 ;;
    --age-recipient)
      [[ $# -ge 2 ]] || { echo "--age-recipient needs a value" >&2; exit 1; }
      AGE_RECIPIENTS+=("$2"); shift 2 ;;
    --age-identity)
      [[ $# -ge 2 ]] || { echo "--age-identity needs a path" >&2; exit 1; }
      AGE_IDENTITY="$2"; shift 2 ;;
    --passphrase)
      ENCRYPT=1; ENCRYPT_PASSPHRASE=1; shift ;;
    --keep) KEEP="$2"; shift 2 ;;
    --include-model-cache) INCLUDE_MODEL_CACHE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown: $1" >&2; exit 1 ;;
  esac
done

stamp_now() { date +%Y%m%d-%H%M%S; }

db_pod() { kubectl -n "$NS" get pod -l app=database -o jsonpath='{.items[0].metadata.name}'; }
server_pod() { kubectl -n "$NS" get pod -l app=immich-server -o jsonpath='{.items[0].metadata.name}'; }
ml_pod() { kubectl -n "$NS" get pod -l app=immich-machine-learning -o jsonpath='{.items[0].metadata.name}'; }

resolve_snapshot_dir() {
  local path="$1"
  [[ -e "$path" ]] || { echo "Not found: $path" >&2; exit 1; }
  path="$(cd "$path" && pwd)"
  [[ -f "${path}/META.txt" ]] && { printf '%s\n' "$path"; return 0; }
  if [[ -L "${path}/latest" ]]; then
    local target
    target="$(readlink -f "${path}/latest" 2>/dev/null || true)"
    [[ -n "$target" ]] || { target="$(readlink "${path}/latest")"; [[ "$target" == /* ]] || target="${path}/${target}"; }
    [[ -f "${target}/META.txt" ]] && { printf '%s\n' "$(cd "$target" && pwd)"; return 0; }
  fi
  local newest
  newest="$(ls -1dt "${path}"/snapshots/* 2>/dev/null | head -1 || true)"
  [[ -n "$newest" && -f "${newest}/META.txt" ]] && { printf '%s\n' "$(cd "$newest" && pwd)"; return 0; }
  echo "No usable snapshot under: $path" >&2; exit 1
}

prepare_snapshot_dirs() {
  local dest="$1"
  mkdir -p "${dest}/snapshots"
  SNAP_NAME="$(stamp_now)"
  SNAP_DIR="${dest}/snapshots/${SNAP_NAME}"
  mkdir -p "${SNAP_DIR}"
  PREV_LINK=""
  if [[ -L "${dest}/latest" ]]; then
    PREV_LINK="$(readlink "${dest}/latest")"
    [[ "${PREV_LINK}" == /* ]] || PREV_LINK="${dest}/${PREV_LINK}"
  fi
}

finalize_snapshot() {
  ln -sfn "snapshots/${SNAP_NAME}" "${1}/latest"
  echo "Snapshot ready: ${SNAP_DIR}"
}

prune_snapshots() {
  local dest="$1" keep="$2"
  [[ -n "$keep" ]] || return 0
  keep="$(printf '%s' "$keep" | tr -dc '0-9')"
  [[ -n "$keep" && "$keep" -ge 1 ]] || return 0
  mapfile -t snaps < <(ls -1dt "${dest}"/snapshots/* 2>/dev/null || true)
  local total="${#snaps[@]}" i
  if (( total > keep )); then
    for (( i = keep; i < total; i++ )); do echo "Pruning ${snaps[$i]}"; rm -rf "${snaps[$i]}"; done
  fi
}

rsync_incremental() {
  local src="$1" dst="$2" prev="${3:-}"
  mkdir -p "$dst"
  local -a args=(-aH --delete --info=stats2)
  [[ -n "$prev" && -d "$prev" ]] && args+=(--link-dest="$prev") && echo "    Incremental vs: $prev"
  [[ -t 1 ]] && args+=(--info=progress2)
  rsync "${args[@]}" "${src}/" "${dst}/"
}

sha256_file() {
  local f="$1"
  command -v sha256sum >/dev/null && sha256sum "$f" | awk '{print $1}' || echo unavailable
}

verify_pg_dump() {
  local f="$1"
  [[ -s "$f" ]] || { echo "Empty dump: $f" >&2; return 1; }
  if [[ "$f" == *.gz ]]; then
    gzip -t "$f" || return 1
    gzip -dc "$f" | head -c 200 | grep -qE 'PostgreSQL|CREATE|SET' || return 1
  fi
  echo "    Verified dump ($(du -h "$f" | awk '{print $1}'))."
}

seal_snapshot() {
  local snap="$1"
  echo "==> Sealing snapshot..."
  (
    cd "$snap" || exit 1
    rm -f SHA256SUMS LIBRARY_FINGERPRINT
    if [[ -d files/library ]]; then
      find files/library -type f -printf '%s\t%p\n' 2>/dev/null | sort | sha256sum | awk '{print $1}' >LIBRARY_FINGERPRINT
    fi
    find . -type f ! -name SHA256SUMS ! -name META.txt ! -path './files/library/*' -print0 \
      | sort -z | xargs -0 -r sha256sum >SHA256SUMS
  )
  local sum
  sum="$(sha256_file "${snap}/SHA256SUMS")"
  [[ -f "${snap}/META.txt" ]] || printf 'stack=%s\n' "$STACK_ID" >"${snap}/META.txt"
  if grep -q '^snapshot_sha256=' "${snap}/META.txt"; then
    sed -i "s|^snapshot_sha256=.*|snapshot_sha256=${sum}|" "${snap}/META.txt"
  else
    printf 'snapshot_sha256=%s\n' "$sum" >>"${snap}/META.txt"
  fi
  if [[ -f "${snap}/LIBRARY_FINGERPRINT" ]]; then
    local fp; fp="$(cat "${snap}/LIBRARY_FINGERPRINT")"
    if grep -q '^library_fingerprint=' "${snap}/META.txt"; then
      sed -i "s|^library_fingerprint=.*|library_fingerprint=${fp}|" "${snap}/META.txt"
    else
      printf 'library_fingerprint=%s\n' "$fp" >>"${snap}/META.txt"
    fi
  fi
  echo "    snapshot_sha256=${sum}"
}

verify_snapshot_integrity() {
  local snap="$1" warn=0
  echo "==> Checking snapshot integrity..."
  if [[ ! -f "${snap}/SHA256SUMS" ]]; then
    echo "WARNING: No SHA256SUMS." >&2; warn=1
  else
    set +e
    local out rc
    out="$(cd "$snap" && sha256sum -c SHA256SUMS 2>&1)"; rc=$?
    set -e
    if [[ "$rc" -ne 0 ]]; then
      echo "WARNING: SHA256 FAILED — integrity may be lost; restore may cause issues." >&2
      printf '%s\n' "$out" | grep -v ': OK$' | head -40 >&2 || true
      warn=1
    fi
    local expected actual
    expected="$(grep -E '^snapshot_sha256=' "${snap}/META.txt" 2>/dev/null | cut -d= -f2- || true)"
    actual="$(sha256_file "${snap}/SHA256SUMS")"
    [[ -n "$expected" && "$actual" != "$expected" ]] && { echo "WARNING: snapshot_sha256 mismatch." >&2; warn=1; }
  fi
  if [[ -d "${snap}/files/library" && -f "${snap}/LIBRARY_FINGERPRINT" ]]; then
    local expected_fp actual_fp
    expected_fp="$(cat "${snap}/LIBRARY_FINGERPRINT")"
    actual_fp="$(find "${snap}/files/library" -type f -printf '%s\t%p\n' 2>/dev/null | sort | sha256sum | awk '{print $1}')"
    [[ "$actual_fp" != "$expected_fp" ]] && { echo "WARNING: library fingerprint mismatch." >&2; warn=1; }
  fi
  if [[ "$warn" -eq 0 ]]; then echo "    Integrity OK."; else echo "    Continuing despite warnings." >&2; fi
}

pull_pod_tree() {
  local pod="$1" remote="$2" dest="$3"
  mkdir -p "$dest"
  kubectl -n "$NS" exec "$pod" -- tar -C "$remote" -cf - . | tar -C "$dest" -xf -
}

push_pod_tree() {
  local pod="$1" remote="$2" src="$3"
  kubectl -n "$NS" exec "$pod" -- sh -c "rm -rf ${remote}/* ${remote}/.[!.]* ${remote}/..?* 2>/dev/null || true"
  tar -C "$src" -cf - . | kubectl -n "$NS" exec -i "$pod" -- tar -C "$remote" -xf -
}

do_backup() {
  need kubectl; need_rsync
  [[ -n "$DEST" ]] || { echo "Provide --dest" >&2; exit 1; }
  DEST="$(mkdir -p "$DEST" && cd "$DEST" && pwd)"
  prepare_snapshot_dirs "$DEST"
  echo "==> Snapshot ${SNAP_NAME}"

  local dbp sp
  dbp="$(db_pod)"; sp="$(server_pod)"
  [[ -n "$dbp" && -n "$sp" ]] || { echo "Need running database + immich-server pods." >&2; rm -rf "${SNAP_DIR}"; exit 1; }

  trap 'rm -rf "${SNAP_DIR}"' EXIT

  echo "==> Dumping Postgres from ${dbp}..."
  local user db pass
  user="$(kubectl -n "$NS" get secret immich-db -o jsonpath='{.data.DB_USERNAME}' | base64 -d)"
  db="$(kubectl -n "$NS" get secret immich-db -o jsonpath='{.data.DB_DATABASE_NAME}' | base64 -d)"
  pass="$(kubectl -n "$NS" get secret immich-db -o jsonpath='{.data.DB_PASSWORD}' | base64 -d)"
  kubectl -n "$NS" exec "${dbp}" -- \
    env PGPASSWORD="${pass}" pg_dump -U "${user}" -d "${db}" --clean --if-exists \
    | gzip -c >"${SNAP_DIR}/immich-db.sql.gz"
  verify_pg_dump "${SNAP_DIR}/immich-db.sql.gz"

  kubectl -n "$NS" get secret immich-db -o yaml >"${SNAP_DIR}/secret-immich-db.yaml"
  cp -a "${ROOT}/deploy.yaml" "${SNAP_DIR}/" 2>/dev/null || true

  echo "==> Archiving /data (library) from ${sp} (may take a long time)..."
  local staging
  staging="$(mktemp -d)"
  pull_pod_tree "$sp" /data "${staging}/library"
  local prev=""
  [[ -n "${PREV_LINK}" && -d "${PREV_LINK}/files/library" ]] && prev="${PREV_LINK}/files/library"
  rsync_incremental "${staging}/library" "${SNAP_DIR}/files/library" "${prev}"
  rm -rf "$staging"

  if [[ "${INCLUDE_MODEL_CACHE}" -eq 1 ]]; then
    local mlp
    mlp="$(ml_pod 2>/dev/null || true)"
    if [[ -n "$mlp" ]]; then
      echo "==> Archiving model-cache..."
      staging="$(mktemp -d)"
      pull_pod_tree "$mlp" /cache "${staging}/model-cache"
      prev=""
      [[ -n "${PREV_LINK}" && -d "${PREV_LINK}/files/model-cache" ]] && prev="${PREV_LINK}/files/model-cache"
      rsync_incremental "${staging}/model-cache" "${SNAP_DIR}/files/model-cache" "${prev}"
      rm -rf "$staging"
    fi
  fi

  cat >"${SNAP_DIR}/META.txt" <<EOF
stack=${STACK_ID}
created=$(date -Iseconds)
host=$(hostname 2>/dev/null || echo unknown)
note=immich k8s library + verified postgres dump
db_engine=postgresql
db_method=pg_dump
EOF
  trap - EXIT
  seal_snapshot "${SNAP_DIR}"
  maybe_encrypt_after_seal
  finalize_snapshot "$DEST"
  prune_snapshots "$DEST" "${KEEP}"
  echo "Backup OK."
}

do_restore() {
  need kubectl; need_rsync
  [[ -n "$FROM" ]] || { echo "Provide --from" >&2; exit 1; }
  local snap src
  src="$(prepare_restore_from_arg "$FROM")"
  trap cleanup_restore_tmp EXIT
  snap="$(resolve_snapshot_dir "$src")"
  echo "Restoring from: $snap"
  verify_snapshot_integrity "$snap"
  [[ -f "${snap}/immich-db.sql.gz" ]] || { echo "Missing dump" >&2; exit 1; }
  [[ -d "${snap}/files/library" ]] || { echo "Missing library" >&2; exit 1; }

  if [[ -t 0 ]]; then
    read -r -p "Type 'restore' to continue: " confirm || true
    [[ "${confirm}" == "restore" ]] || { echo "Aborted."; exit 1; }
  else
    [[ "${CONFIRM_RESTORE:-}" == "yes" ]] || exit 1
  fi

  if ! kubectl -n "$NS" get deploy immich-server >/dev/null 2>&1; then
    apply_manifest "${ROOT}/deploy.yaml"
  fi
  if [[ -f "${snap}/secret-immich-db.yaml" ]]; then
    kubectl -n "$NS" apply -f "${snap}/secret-immich-db.yaml"
  fi

  echo "==> Scaling Immich server down during DB import..."
  kubectl -n "$NS" scale deployment/immich-server --replicas=0
  kubectl -n "$NS" wait --for=delete pod -l app=immich-server --timeout=180s 2>/dev/null || true
  kubectl -n "$NS" rollout status deployment/database --timeout=300s

  local dbp user db pass
  dbp="$(db_pod)"
  user="$(kubectl -n "$NS" get secret immich-db -o jsonpath='{.data.DB_USERNAME}' | base64 -d)"
  db="$(kubectl -n "$NS" get secret immich-db -o jsonpath='{.data.DB_DATABASE_NAME}' | base64 -d)"
  pass="$(kubectl -n "$NS" get secret immich-db -o jsonpath='{.data.DB_PASSWORD}' | base64 -d)"
  echo "==> Importing SQL..."
  if ! gzip -dc "${snap}/immich-db.sql.gz" \
    | kubectl -n "$NS" exec -i "${dbp}" -- env PGPASSWORD="${pass}" psql -U "${user}" -d "${db}"; then
    echo "SQL IMPORT FAILED — leaving server scaled to 0." >&2
    exit 1
  fi

  kubectl -n "$NS" scale deployment/immich-server --replicas=1
  kubectl -n "$NS" rollout status deployment/immich-server --timeout=300s
  local sp
  sp="$(server_pod)"
  echo "==> Restoring library into ${sp}..."
  push_pod_tree "$sp" /data "${snap}/files/library"

  if [[ -d "${snap}/files/model-cache" ]]; then
    local mlp
    mlp="$(ml_pod)"
    push_pod_tree "$mlp" /cache "${snap}/files/model-cache"
  fi

  kubectl -n "$NS" rollout restart deployment/immich-server deployment/immich-machine-learning
  kubectl -n "$NS" rollout status deployment/immich-server --timeout=300s
  echo "Restore finished from ${snap}."
}

case "${MODE}" in
  backup) do_backup ;;
  restore) do_restore ;;
  *) usage >&2; exit 1 ;;
esac

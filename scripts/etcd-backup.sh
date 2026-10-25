#!/bin/sh
# Periodic ETCD snapshot backups.
#   BACKUP_INTERVAL : seconds between snapshots (default 3600)
#   KEEP_BACKUPS    : number of snapshots to retain (default 24)

set -eu

INTERVAL="${BACKUP_INTERVAL:-3600}"
KEEP="${KEEP_BACKUPS:-24}"
BACKUP_DIR="/backups"

echo "[etcd-backup] started: interval=${INTERVAL}s keep=${KEEP} endpoints=${ETCDCTL_ENDPOINTS}"

while true; do
  ts="$(date -u +%Y%m%dT%H%M%SZ)"
  file="${BACKUP_DIR}/etcd-snapshot-${ts}.tar"

  if etcdctl --endpoints="${ETCDCTL_ENDPOINTS:-http://etcd:2379}" \
      --command-timeout=10s snapshot save "${file}"; then
    echo "[etcd-backup] saved ${file} ($(du -h "${file}" | cut -f1))"
  else
    echo "[etcd-backup] WARN: snapshot failed, will retry next interval"
    rm -f "${file}"
  fi

  # Retention: keep only the newest $KEEP snapshots
  ls -1t "${BACKUP_DIR}"/etcd-snapshot-*.tar 2>/dev/null | tail -n +$((KEEP + 1)) | while read -r old; do
    echo "[etcd-backup] removing old backup ${old}"
    rm -f "${old}"
  done

  sleep "${INTERVAL}"
done

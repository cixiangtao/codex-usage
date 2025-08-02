#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="CodexUsage"
POLL_INTERVAL="${POLL_INTERVAL:-1}"
DEBOUNCE_SECONDS="${DEBOUNCE_SECONDS:-0.35}"

child_pid=""

dev_app_pids() {
  local pid
  while read -r pid; do
    if [[ -z "${pid}" || "${pid}" == "$$" ]]; then
      continue
    fi

    if lsof -a -p "${pid}" -d cwd 2>/dev/null | awk 'NR > 1 { print $NF }' | grep -qx "${ROOT_DIR}"; then
      printf '%s\n' "${pid}"
    fi
  done < <(pgrep -f "(^|/)${APP_NAME}$|\\.build/.*/${APP_NAME}$" 2>/dev/null || true)
}

stop_app() {
  if [[ -n "${child_pid}" ]] && kill -0 "${child_pid}" 2>/dev/null; then
    kill "${child_pid}" 2>/dev/null || true
    wait "${child_pid}" 2>/dev/null || true
  fi

  local pid
  for pid in $(dev_app_pids); do
    if [[ "${pid}" != "$$" ]]; then
      kill "${pid}" 2>/dev/null || true
    fi
  done

  child_pid=""
}

cleanup() {
  stop_app
}

trap cleanup EXIT INT TERM

usage() {
  cat <<EOF
Usage: scripts/dev-watch.sh

Environment:
  POLL_INTERVAL      Seconds between file checks. Default: ${POLL_INTERVAL}
  DEBOUNCE_SECONDS   Delay before restart after changes. Default: ${DEBOUNCE_SECONDS}
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

fingerprint() {
  (
    cd "${ROOT_DIR}"
    find Package.swift Sources WidgetExtension \
      \( -name '*.swift' -o -name 'Package.swift' \) \
      -type f -print0 2>/dev/null \
      | xargs -0 stat -f '%m %z %N' 2>/dev/null \
      | shasum
  )
}

start_app() {
  printf '\n[%s] Starting %s...\n' "$(date '+%H:%M:%S')" "${APP_NAME}"
  (
    cd "${ROOT_DIR}"
    swift run "${APP_NAME}"
  ) &
  child_pid="$!"
}

restart_app() {
  printf '[%s] Stopping %s...\n' "$(date '+%H:%M:%S')" "${APP_NAME}"
  stop_app
  start_app
}

printf '[%s] Watching %s\n' "$(date '+%H:%M:%S')" "${ROOT_DIR}"
printf '[%s] Press Ctrl-C to stop.\n' "$(date '+%H:%M:%S')"

last_fingerprint="$(fingerprint)"
stop_app
start_app

while true; do
  sleep "${POLL_INTERVAL}"

  next_fingerprint="$(fingerprint)"
  if [[ "${next_fingerprint}" == "${last_fingerprint}" ]]; then
    continue
  fi

  sleep "${DEBOUNCE_SECONDS}"
  next_fingerprint="$(fingerprint)"
  last_fingerprint="${next_fingerprint}"

  printf '\n[%s] Change detected. Rebuilding...\n' "$(date '+%H:%M:%S')"
  restart_app
done

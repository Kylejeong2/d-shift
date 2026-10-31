#!/usr/bin/env bash
# Runs D-Shift and restarts it whenever Sources/ or Package.swift change.
# A failed build leaves the running app alone and prints the errors.
#
#   ./scripts/dev.sh
set -uo pipefail

cd "$(dirname "$0")/.."
binary=".build/arm64-apple-macosx/debug/DShift"
app_pid=""

fingerprint() {
  find Sources Package.swift -type f \( -name '*.swift' -o -name 'Package.swift' \) -exec stat -f '%m %N' {} + | sort | shasum
}

stop_app() {
  if [[ -n "$app_pid" ]] && kill -0 "$app_pid" 2>/dev/null; then
    kill "$app_pid"
    wait "$app_pid" 2>/dev/null
  fi
  app_pid=""
}

build_and_restart() {
  echo "[dev] building..."
  local output
  if ! output=$(swift build --product DShift 2>&1); then
    echo "$output" | grep -E 'error' -A3
    echo "[dev] build failed, keeping the current app running"
    return
  fi
  stop_app
  # D-Shift refuses to start while another copy runs (see SingleInstance.swift), so stop whichever copy holds the
  # lock, even one started from another checkout.
  local lock="${TMPDIR%/}/dshift.lock" running
  if running=$(cat "$lock" 2>/dev/null) && [[ -n "$running" ]] && kill "$running" 2>/dev/null; then
    while kill -0 "$running" 2>/dev/null; do sleep 0.1; done
  fi
  "$binary" &
  app_pid=$!
  echo "[dev] running pid $app_pid"
}

trap 'stop_app; exit 0' INT TERM

build_and_restart
last=$(fingerprint)
while true; do
  sleep 1
  current=$(fingerprint)
  if [[ "$current" != "$last" ]]; then
    last=$current
    sleep 0.5 # let multi-file edits land
    last=$(fingerprint)
    build_and_restart
  fi
done

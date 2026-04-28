#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PID_DIR="$ROOT_DIR/.native-run/pids"

stop_pidfile() {
  local pidfile="$1"
  if [[ -f "$pidfile" ]]; then
    local pid
    pid="$(cat "$pidfile")"
    if kill -0 "$pid" >/dev/null 2>&1; then
      kill "$pid" >/dev/null 2>&1 || true
      wait "$pid" 2>/dev/null || true
    fi
    rm -f "$pidfile"
  fi
}

for name in \
  nginx \
  web \
  clsi \
  history-v1 \
  real-time \
  project-history \
  notifications \
  filestore \
  document-updater \
  docstore \
  contacts \
  chat
do
  stop_pidfile "$PID_DIR/$name.pid"
done

if [[ -f "$PID_DIR/redis.pid" ]]; then
  redis-cli shutdown >/dev/null 2>&1 || true
  rm -f "$PID_DIR/redis.pid"
fi

if pgrep -x mongod >/dev/null 2>&1; then
  mongosh --quiet --eval "db.adminCommand({ shutdown: 1, force: true })" >/dev/null 2>&1 || true
fi

echo "Stopped native Overleaf services."

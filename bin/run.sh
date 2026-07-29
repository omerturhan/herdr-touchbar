#!/usr/bin/env bash
# Lifecycle helper for HerdrTouchBar.app. Used by the plugin actions and the
# LaunchAgent; safe to call repeatedly.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/build/HerdrTouchBar.app"
BIN="$APP/Contents/MacOS/HerdrTouchBar"
READY="$ROOT/build/HerdrTouchBar.ready"

running_pids() {
  local pid command
  while read -r pid command; do
    if [ "$command" = "$BIN" ]; then
      printf '%s\n' "$pid"
    fi
  done < <(ps -axo pid=,command=)
}

running() {
  [ -n "$(running_pids)" ]
}

ready() {
  local ready_pid
  [ -r "$READY" ] || return 1
  IFS= read -r ready_pid < "$READY"
  [ -n "$ready_pid" ] && running_pids | grep -Fxq "$ready_pid"
}

wait_until_ready() {
  local _
  for _ in {1..50}; do
    ready && return 0
    sleep 0.1
  done
  echo "error: HerdrTouchBar.app did not become ready" >&2
  return 1
}

wait_until_stopped() {
  local _
  for _ in {1..30}; do
    running || return 0
    sleep 0.1
  done
  echo "error: HerdrTouchBar.app did not stop" >&2
  return 1
}

signal_app() {
  local signal_name="$1"
  local pid
  while IFS= read -r pid; do
    [ -n "$pid" ] && kill "-$signal_name" "$pid"
  done < <(running_pids)
}

ensure_built() {
  if [ ! -x "$BIN" ]; then
    echo "HerdrTouchBar.app not built yet; building..." >&2
    bash "$ROOT/build.sh" >&2
  fi
}

start() {
  ensure_built
  if ! running; then
    rm -f "$READY"
    open -g "$APP"
  fi
  wait_until_ready
}

stop() {
  if running; then
    signal_app TERM
    wait_until_stopped
    rm -f "$READY"
    echo "stopped"
  else
    rm -f "$READY"
    echo "not running"
  fi
}

case "${1:-ensure}" in
  ensure)
    running || start
    ;;
  start)
    start
    ;;
  restart)
    stop >/dev/null
    start
    echo "restarted"
    ;;
  stop)
    stop
    ;;
  open)
    running || start
    signal_app USR1
    ;;
  close)
    if running; then
      signal_app USR2
    fi
    ;;
  status)
    if running; then
      echo "running (pid $(running_pids | paste -sd ' ' -))"
    else
      echo "not running"
    fi
    [ -x "$BIN" ] && echo "binary: $BIN" || echo "binary: not built"
    ;;
  *)
    echo "usage: run.sh [ensure|start|restart|stop|open|close|status]" >&2
    exit 2
    ;;
esac

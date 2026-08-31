#!/bin/bash

set -u

BASE_DIR="${MATVEEV_BASE_DIR:-/Library/Application Support/matveevVpn}"
CONTROL_DIR="$BASE_DIR/control"
RUN_DIR="$BASE_DIR/run"
SING_BOX="$BASE_DIR/bin/sing-box"
CONFIG_FILE="$BASE_DIR/config.json"
PENDING_CONFIG="$CONTROL_DIR/pending-config.json"
COMMAND_FILE="$CONTROL_DIR/command"
STATUS_FILE="$CONTROL_DIR/runtime-status"
DESIRED_FILE="$RUN_DIR/desired-state"
PID_FILE="$RUN_DIR/sing-box.pid"
LOG_FILE="${MATVEEV_LOG_FILE:-/tmp/matveev-vpn.log}"
ERROR_FILE="${MATVEEV_ERROR_FILE:-/tmp/matveev-vpn.error.log}"

CHILD_PID=""

/bin/mkdir -p "$CONTROL_DIR" "$RUN_DIR"

write_status() {
  local value="$1"
  local temporary
  temporary="$(/usr/bin/mktemp "$CONTROL_DIR/.runtime-status.XXXXXX")" || return 1
  /usr/bin/printf '%s\n' "$value" > "$temporary"
  /bin/chmod 644 "$temporary"
  /bin/mv -f "$temporary" "$STATUS_FILE"
}

write_response() {
  local token="$1"
  local value="$2"
  local response="$CONTROL_DIR/response-$token"
  local temporary
  temporary="$(/usr/bin/mktemp "$CONTROL_DIR/.response.XXXXXX")" || return 1
  /usr/bin/printf '%s\n' "$value" > "$temporary"
  /bin/chmod 644 "$temporary"
  /bin/mv -f "$temporary" "$response"
}

child_running() {
  [[ -n "$CHILD_PID" ]] && /bin/kill -0 "$CHILD_PID" 2>/dev/null
}

start_child() {
  if child_running; then
    write_status "running"
    return 0
  fi
  if [[ ! -x "$SING_BOX" || ! -f "$CONFIG_FILE" ]]; then
    write_status "error"
    return 1
  fi
  if ! "$SING_BOX" check -c "$CONFIG_FILE" >> "$ERROR_FILE" 2>&1; then
    write_status "error"
    return 1
  fi

  "$SING_BOX" run -c "$CONFIG_FILE" >> "$LOG_FILE" 2>> "$ERROR_FILE" &
  CHILD_PID=$!
  /usr/bin/printf '%s\n' "$CHILD_PID" > "$PID_FILE"
  /bin/sleep 1
  if child_running; then
    write_status "running"
    return 0
  fi
  CHILD_PID=""
  /bin/rm -f "$PID_FILE"
  write_status "error"
  return 1
}

stop_child() {
  if child_running; then
    /bin/kill -TERM "$CHILD_PID" 2>/dev/null || true
    local attempt
    for attempt in 1 2 3 4 5; do
      child_running || break
      /bin/sleep 1
    done
    if child_running; then
      /bin/kill -KILL "$CHILD_PID" 2>/dev/null || true
    fi
    wait "$CHILD_PID" 2>/dev/null || true
  fi
  CHILD_PID=""
  /bin/rm -f "$PID_FILE"
  write_status "stopped"
}

set_desired() {
  /usr/bin/printf '%s\n' "$1" > "$DESIRED_FILE"
  /bin/chmod 600 "$DESIRED_FILE"
}

desired_state() {
  if [[ -f "$DESIRED_FILE" ]]; then
    /usr/bin/head -n 1 "$DESIRED_FILE" | /usr/bin/tr -d '[:space:]'
  else
    echo "on"
  fi
}

reload_config() {
  if [[ ! -f "$PENDING_CONFIG" || -L "$PENDING_CONFIG" ]]; then
    return 1
  fi
  if ! "$SING_BOX" check -c "$PENDING_CONFIG" >> "$ERROR_FILE" 2>&1; then
    return 1
  fi
  if [[ -n "${MATVEEV_BASE_DIR:-}" ]]; then
    /usr/bin/install -m 600 "$PENDING_CONFIG" "$CONFIG_FILE"
  else
    /usr/bin/install -o root -g wheel -m 600 "$PENDING_CONFIG" "$CONFIG_FILE"
  fi
  /bin/rm -f "$PENDING_CONFIG"
  if [[ "$(desired_state)" == "on" ]]; then
    stop_child
    start_child
  else
    write_status "stopped"
  fi
}

process_command() {
  local action=""
  local token=""
  read -r action token < "$COMMAND_FILE" || true
  /bin/rm -f "$COMMAND_FILE"
  if [[ ! "$token" =~ ^[A-Za-z0-9._-]+$ ]]; then
    return 0
  fi

  case "$action" in
    on)
      set_desired "on"
      if start_child; then write_response "$token" "ok"; else write_response "$token" "error"; fi
      ;;
    off)
      set_desired "off"
      stop_child
      write_response "$token" "ok"
      ;;
    restart)
      set_desired "on"
      stop_child
      if start_child; then write_response "$token" "ok"; else write_response "$token" "error"; fi
      ;;
    reload)
      if reload_config; then write_response "$token" "ok"; else write_response "$token" "error"; fi
      ;;
    *)
      write_response "$token" "error"
      ;;
  esac
}

shutdown() {
  stop_child
  exit 0
}
trap shutdown TERM INT HUP

if [[ "$(desired_state)" == "on" ]]; then
  start_child || true
else
  write_status "stopped"
fi

while true; do
  if [[ -f "$COMMAND_FILE" ]]; then
    process_command
  fi
  if [[ "$(desired_state)" == "on" ]] && ! child_running; then
    start_child || true
  fi
  /bin/sleep 0.5
done

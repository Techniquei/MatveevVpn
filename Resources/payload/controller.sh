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
ROLLBACK_CONFIG="$RUN_DIR/config.rollback.json"
LOG_FILE="${MATVEEV_LOG_FILE:-/tmp/matveev-vpn.log}"
ERROR_FILE="${MATVEEV_ERROR_FILE:-/tmp/matveev-vpn.error.log}"
WATCHDOG_GAP_SECONDS="${MATVEEV_WATCHDOG_GAP_SECONDS:-10}"

CHILD_PID=""
LAST_TICK="$(/bin/date +%s)"
LAST_NETWORK_CHECK=0
LAST_NETWORK_SIGNATURE=""
TUN_MISSES=0

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

tunnel_interface() {
  /sbin/ifconfig 2>/dev/null | /usr/bin/awk '
    /^[A-Za-z0-9]+:/ { interface=$1; sub(":", "", interface) }
    /inet 198\.18\.0\.1 / { print interface; exit }
  '
}

log_event() {
  /usr/bin/printf '%s controller: %s\n' "$(/bin/date '+%Y-%m-%d %H:%M:%S')" "$1"
}

install_config() {
  local source="$1"
  if [[ -n "${MATVEEV_BASE_DIR:-}" ]]; then
    /usr/bin/install -m 600 "$source" "$CONFIG_FILE"
  else
    /usr/bin/install -o root -g wheel -m 600 "$source" "$CONFIG_FILE"
  fi
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

cleanup_tunnel_state() {
  local interface="$1" destination
  [[ "$interface" =~ ^utun[0-9]+$ ]] || return 0

  while IFS= read -r destination; do
    [[ -n "$destination" ]] || continue
    /sbin/route -n delete -inet -ifscope "$interface" "$destination" >/dev/null 2>&1 || true
  done < <(/usr/sbin/netstat -rn -f inet 2>/dev/null | /usr/bin/awk -v interface="$interface" '$4 == interface {print $1}')

  if /sbin/ifconfig "$interface" 2>/dev/null | /usr/bin/grep -q 'inet 198\.18\.0\.1 '; then
    /sbin/ifconfig "$interface" down >/dev/null 2>&1 || true
  fi
  /usr/bin/dscacheutil -flushcache >/dev/null 2>&1 || true
  /usr/bin/killall -HUP mDNSResponder >/dev/null 2>&1 || true
}

stop_child() {
  local owned_interface
  owned_interface="$(tunnel_interface)"
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
  if [[ -z "${MATVEEV_BASE_DIR:-}" && -n "$owned_interface" ]]; then
    cleanup_tunnel_state "$owned_interface"
  fi
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
  local had_previous=false
  if [[ -f "$CONFIG_FILE" ]]; then
    /usr/bin/install -m 600 "$CONFIG_FILE" "$ROLLBACK_CONFIG"
    had_previous=true
  fi
  install_config "$PENDING_CONFIG" || return 1
  /bin/rm -f "$PENDING_CONFIG"
  if [[ "$(desired_state)" == "on" ]]; then
    stop_child
    if start_child; then
      /bin/rm -f "$ROLLBACK_CONFIG"
      return 0
    fi
    log_event "new configuration failed; restoring the previous configuration"
    if [[ "$had_previous" == true ]]; then
      install_config "$ROLLBACK_CONFIG" || return 1
      /bin/rm -f "$ROLLBACK_CONFIG"
      stop_child
      start_child || true
    fi
    return 1
  else
    /bin/rm -f "$ROLLBACK_CONFIG"
    write_status "stopped"
  fi
}

network_signature() {
  local route_info interface gateway
  route_info="$(/sbin/route -n get default 2>/dev/null || true)"
  interface="$(/usr/bin/awk '/interface:/{print $2; exit}' <<< "$route_info")"
  gateway="$(/usr/bin/awk '/gateway:/{print $2; exit}' <<< "$route_info")"
  if [[ -n "$interface" ]]; then
    /usr/bin/printf '%s|%s\n' "$interface" "$gateway"
  else
    /usr/bin/printf 'offline\n'
  fi
}

tunnel_ready() {
  if [[ -n "${MATVEEV_BASE_DIR:-}" ]]; then
    return 0
  fi
  /sbin/ifconfig 2>/dev/null | /usr/bin/grep -q 'inet 198\.18\.0\.1 '
}

recover_child() {
  local reason="$1"
  log_event "restarting VPN after $reason"
  stop_child
  start_child || true
}

run_watchdog() {
  local now gap signature recovered=false
  now="$(/bin/date +%s)"
  gap=$((now - LAST_TICK))

  if [[ "$gap" -gt "$WATCHDOG_GAP_SECONDS" ]] && child_running; then
    recover_child "sleep or a scheduler pause"
    recovered=true
  fi

  if [[ $((now - LAST_NETWORK_CHECK)) -ge 5 ]]; then
    signature="$(network_signature)"
    if [[ -n "$LAST_NETWORK_SIGNATURE" && "$signature" != "$LAST_NETWORK_SIGNATURE" && "$signature" != "offline" ]] && child_running; then
      recover_child "a network interface change"
      recovered=true
    fi
    LAST_NETWORK_SIGNATURE="$signature"
    LAST_NETWORK_CHECK="$now"

    if tunnel_ready; then
      TUN_MISSES=0
    else
      TUN_MISSES=$((TUN_MISSES + 1))
      if [[ "$TUN_MISSES" -ge 2 ]] && child_running; then
        recover_child "the TUN interface disappeared"
        TUN_MISSES=0
        recovered=true
      fi
    fi
  fi

  if [[ "$recovered" == true ]]; then
    LAST_NETWORK_SIGNATURE="$(network_signature)"
    LAST_NETWORK_CHECK="$now"
    TUN_MISSES=0
  fi
  LAST_TICK="$now"
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
LAST_NETWORK_SIGNATURE="$(network_signature)"
LAST_NETWORK_CHECK="$(/bin/date +%s)"

while true; do
  if [[ -f "$COMMAND_FILE" ]]; then
    process_command
  fi
  if [[ "$(desired_state)" == "on" ]] && ! child_running; then
    start_child || true
  fi
  if [[ "$(desired_state)" == "on" ]]; then
    run_watchdog
  else
    LAST_TICK="$(/bin/date +%s)"
  fi
  /bin/sleep 0.5
done

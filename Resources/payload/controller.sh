#!/bin/bash

set -u
umask 077

BASE_DIR="${MATVEEV_BASE_DIR:-/Library/Application Support/matveevVpn}"
CONTROL_DIR="$BASE_DIR/control"
RUN_DIR="$BASE_DIR/run"
SING_BOX="$BASE_DIR/bin/sing-box"
XRAY="$BASE_DIR/bin/xray"
DNS_MANAGER="$BASE_DIR/bin/dns-manager.sh"
CONFIG_FILE="$BASE_DIR/config.json"
XRAY_CONFIG_FILE="$BASE_DIR/xray.json"
PENDING_CONFIG="$CONTROL_DIR/pending-config.json"
PENDING_XRAY_CONFIG="$CONTROL_DIR/pending-xray.json"
COMMAND_FILE="$CONTROL_DIR/command"
STATUS_FILE="$CONTROL_DIR/runtime-status"
DESIRED_FILE="$RUN_DIR/desired-state"
PID_FILE="$RUN_DIR/sing-box.pid"
XRAY_PID_FILE="$RUN_DIR/xray.pid"
ROLLBACK_CONFIG="$RUN_DIR/config.rollback.json"
ROLLBACK_XRAY_CONFIG="$RUN_DIR/xray.rollback.json"
LOG_FILE="${MATVEEV_LOG_FILE:-$RUN_DIR/vpn.log}"
ERROR_FILE="${MATVEEV_ERROR_FILE:-$RUN_DIR/vpn.error.log}"
WATCHDOG_GAP_SECONDS="${MATVEEV_WATCHDOG_GAP_SECONDS:-10}"
MAX_LOG_BYTES="${MATVEEV_MAX_LOG_BYTES:-3000000}"
MAX_START_FAILURES="${MATVEEV_MAX_START_FAILURES:-3}"

CHILD_PID=""
XRAY_PID=""
LAST_TICK="$(/bin/date +%s)"
LAST_NETWORK_CHECK=0
LAST_NETWORK_SIGNATURE=""
LAST_DEFAULT_ROUTE_SIGNATURE=""
TUN_MISSES=0
LAST_STATUS_PUBLISH=0
START_FAILURES=0

/bin/mkdir -p "$CONTROL_DIR" "$RUN_DIR"

bounded_log_line() {
  local file="$1" line="$2" lock temporary size entry_size keep lock_attempt=0
  lock="$RUN_DIR/.log-lock-$(/usr/bin/basename "$file")"
  while ! /bin/mkdir "$lock" 2>/dev/null; do
    lock_attempt=$((lock_attempt + 1))
    [[ "$lock_attempt" -lt 500 ]] || return 1
    /bin/sleep 0.01
  done
  temporary="$(/usr/bin/mktemp "$RUN_DIR/.bounded-log.XXXXXX")" || { /bin/rmdir "$lock"; return 1; }
  /usr/bin/printf '%s\n' "$line" > "$temporary"
  entry_size="$(/usr/bin/wc -c < "$temporary" | /usr/bin/tr -d '[:space:]')"
  if [[ "$entry_size" -gt "$MAX_LOG_BYTES" ]]; then
    /usr/bin/tail -c "$MAX_LOG_BYTES" "$temporary" > "$file"
  else
    size="$(/usr/bin/wc -c < "$file" 2>/dev/null | /usr/bin/tr -d '[:space:]')"
    size="${size:-0}"
    if [[ $((size + entry_size)) -gt "$MAX_LOG_BYTES" ]]; then
      keep=$((MAX_LOG_BYTES - entry_size))
      if [[ "$keep" -gt 0 && -f "$file" ]]; then /usr/bin/tail -c "$keep" "$file" > "$temporary.retained"; else : > "$temporary.retained"; fi
      /bin/cat "$temporary" >> "$temporary.retained"
      /bin/mv -f "$temporary.retained" "$file"
    else
      /bin/cat "$temporary" >> "$file"
    fi
  fi
  /bin/chmod 600 "$file" 2>/dev/null || true
  /bin/rm -f "$temporary" "$temporary.retained"
  /bin/rmdir "$lock"
}

bounded_logger() {
  local file="$1" line
  while IFS= read -r line || [[ -n "$line" ]]; do bounded_log_line "$file" "$line"; done
}

prepare_log() {
  local file="$1" size temporary
  [[ -f "$file" ]] || { : > "$file"; /bin/chmod 600 "$file"; return; }
  size="$(/usr/bin/wc -c < "$file" | /usr/bin/tr -d '[:space:]')"
  if [[ "$size" -gt "$MAX_LOG_BYTES" ]]; then
    temporary="$(/usr/bin/mktemp "$RUN_DIR/.trim-log.XXXXXX")" || return
    /usr/bin/tail -c "$MAX_LOG_BYTES" "$file" > "$temporary"
    /bin/mv -f "$temporary" "$file"
  fi
  /bin/chmod 600 "$file" 2>/dev/null || true
}

/bin/rmdir "$RUN_DIR/.log-lock-$(/usr/bin/basename "$LOG_FILE")" 2>/dev/null || true
/bin/rmdir "$RUN_DIR/.log-lock-$(/usr/bin/basename "$ERROR_FILE")" 2>/dev/null || true
prepare_log "$LOG_FILE"
prepare_log "$ERROR_FILE"

publish_recent_errors() {
  local temporary owner_uid owner_gid
  temporary="$(/usr/bin/mktemp "$CONTROL_DIR/.last-error.XXXXXX")" || return 1
  {
    /usr/bin/printf '%s\n' "Controller status: $(/usr/bin/head -n 1 "$STATUS_FILE" 2>/dev/null || /usr/bin/printf unavailable)"
    /usr/bin/printf '%s\n' "Desired state: $(/usr/bin/head -n 1 "$DESIRED_FILE" 2>/dev/null || /usr/bin/printf unavailable)"
    /usr/bin/printf '%s\n' 'Recent runtime output:'
    /usr/bin/tail -c 128000 "$ERROR_FILE" 2>/dev/null || true
  } > "$temporary"
  if [[ -z "${MATVEEV_BASE_DIR:-}" ]]; then
    owner_uid="$(/usr/bin/stat -f '%u' "$CONTROL_DIR")"
    owner_gid="$(/usr/bin/stat -f '%g' "$CONTROL_DIR")"
    /usr/sbin/chown "$owner_uid:$owner_gid" "$temporary" || { /bin/rm -f "$temporary"; return 1; }
  fi
  /bin/chmod 600 "$temporary"
  /bin/mv -f "$temporary" "$CONTROL_DIR/last-error.log"
}

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
  if [[ "$value" != "ok" ]]; then publish_recent_errors || true; else /bin/rm -f "$CONTROL_DIR/last-error.log"; fi
  temporary="$(/usr/bin/mktemp "$CONTROL_DIR/.response.XXXXXX")" || return 1
  /usr/bin/printf '%s\n' "$value" > "$temporary"
  /bin/chmod 644 "$temporary"
  /bin/mv -f "$temporary" "$response"
}

child_running() {
  [[ -n "$CHILD_PID" ]] && /bin/kill -0 "$CHILD_PID" 2>/dev/null
}

xray_running() {
  [[ -n "$XRAY_PID" ]] && /bin/kill -0 "$XRAY_PID" 2>/dev/null
}

runtime_running() {
  child_running && { [[ ! -f "$XRAY_CONFIG_FILE" ]] || xray_running; }
}

tunnel_interface() {
  /sbin/ifconfig 2>/dev/null | /usr/bin/awk '
    /^[A-Za-z0-9]+:/ { interface=$1; sub(":", "", interface) }
    /inet 198\.18\.0\.1 / { print interface; exit }
  '
}

log_event() {
  bounded_log_line "$LOG_FILE" "$(/bin/date '+%Y-%m-%d %H:%M:%S') controller: $1"
}

install_config() {
  local source="$1"
  if [[ -n "${MATVEEV_BASE_DIR:-}" ]]; then
    /usr/bin/install -m 600 "$source" "$CONFIG_FILE"
  else
    /usr/bin/install -o root -g wheel -m 600 "$source" "$CONFIG_FILE"
  fi
}

publish_config_hash() {
  [[ -f "$CONFIG_FILE" ]] || return 0
  local temporary
  temporary="$(/usr/bin/mktemp "$CONTROL_DIR/.config-hash.XXXXXX")" || return 1
  /usr/bin/shasum -a 256 "$CONFIG_FILE" | /usr/bin/awk '{print $1}' > "$temporary"
  /bin/chmod 644 "$temporary"
  /bin/mv -f "$temporary" "$CONTROL_DIR/config-sha256"
}

dns_policy() {
  /usr/bin/ruby -rjson -e '
    config = JSON.parse(File.read(ARGV.fetch(0)))
    puts config.dig("route", "final") == "vpn" ? "system" : "tunnel-only"
  ' "$CONFIG_FILE" 2>/dev/null || /usr/bin/printf 'unknown\n'
}

configure_system_dns() {
  [[ -x "$DNS_MANAGER" ]] || return 0
  local policy
  policy="$(dns_policy)"
  if [[ "$policy" == "system" ]]; then
    "$DNS_MANAGER" apply > >(bounded_logger "$LOG_FILE") 2> >(bounded_logger "$ERROR_FILE") || return 1
    log_event "DNS policy: system override enabled for All Traffic mode"
  else
    "$DNS_MANAGER" restore > >(bounded_logger "$LOG_FILE") 2> >(bounded_logger "$ERROR_FILE") || return 1
    log_event "DNS policy: physical network DNS preserved for Selective mode"
  fi
}

start_child() {
  if runtime_running; then
    write_status "running"
    return 0
  fi
  if child_running || xray_running; then
    stop_child
  fi
  if [[ ! -x "$SING_BOX" || ! -f "$CONFIG_FILE" ]]; then
    write_status "error"
    return 1
  fi
  if ! "$SING_BOX" check -c "$CONFIG_FILE" > >(bounded_logger "$ERROR_FILE") 2>&1; then
    write_status "error"
    return 1
  fi

  if [[ -f "$XRAY_CONFIG_FILE" ]]; then
    if [[ ! -x "$XRAY" ]] || ! "$XRAY" run -test -c "$XRAY_CONFIG_FILE" > >(bounded_logger "$ERROR_FILE") 2>&1; then
      write_status "error"
      return 1
    fi
    "$XRAY" run -c "$XRAY_CONFIG_FILE" > >(bounded_logger "$LOG_FILE") 2> >(bounded_logger "$ERROR_FILE") &
    XRAY_PID=$!
    /usr/bin/printf '%s\n' "$XRAY_PID" > "$XRAY_PID_FILE"
    /bin/sleep 0.2
    if ! xray_running; then
      XRAY_PID=""
      /bin/rm -f "$XRAY_PID_FILE"
      write_status "error"
      return 1
    fi
  fi

  "$SING_BOX" run -c "$CONFIG_FILE" > >(bounded_logger "$LOG_FILE") 2> >(bounded_logger "$ERROR_FILE") &
  CHILD_PID=$!
  /usr/bin/printf '%s\n' "$CHILD_PID" > "$PID_FILE"
  /bin/sleep 1
  local ready_attempt
  for ready_attempt in {1..25}; do
    child_running || break
    if tunnel_ready; then
      if ! configure_system_dns; then
        log_event "could not apply the DNS policy"
        stop_child
        write_status "error"
        return 1
      fi
      write_status "running"
      return 0
    fi
    /bin/sleep 0.2
  done
  stop_child
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
  while IFS= read -r destination; do
    [[ -n "$destination" ]] || continue
    /sbin/route -n delete -inet6 -ifscope "$interface" "$destination" >/dev/null 2>&1 || true
  done < <(/usr/sbin/netstat -rn -f inet6 2>/dev/null | /usr/bin/awk -v interface="$interface" '$4 == interface {print $1}')

  if /sbin/ifconfig "$interface" 2>/dev/null | /usr/bin/grep -q 'inet 198\.18\.0\.1 '; then
    /sbin/ifconfig "$interface" down >/dev/null 2>&1 || true
  fi
  /usr/bin/dscacheutil -flushcache >/dev/null 2>&1 || true
  /usr/bin/killall -HUP mDNSResponder >/dev/null 2>&1 || true
}

stop_child() {
  local owned_interface
  owned_interface="$(tunnel_interface)"
  if [[ -x "$DNS_MANAGER" ]]; then
    "$DNS_MANAGER" restore > >(bounded_logger "$LOG_FILE") 2> >(bounded_logger "$ERROR_FILE") || log_event "could not restore system DNS"
  fi
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
  if xray_running; then
    /bin/kill -TERM "$XRAY_PID" 2>/dev/null || true
    local xray_attempt
    for xray_attempt in 1 2 3 4 5; do
      xray_running || break
      /bin/sleep 1
    done
    if xray_running; then
      /bin/kill -KILL "$XRAY_PID" 2>/dev/null || true
    fi
    wait "$XRAY_PID" 2>/dev/null || true
  fi
  XRAY_PID=""
  /bin/rm -f "$XRAY_PID_FILE"
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
  if [[ ! -f "$PENDING_CONFIG" || -L "$PENDING_CONFIG" || -L "$PENDING_XRAY_CONFIG" ]]; then
    return 1
  fi
  if ! "$SING_BOX" check -c "$PENDING_CONFIG" > >(bounded_logger "$ERROR_FILE") 2>&1; then
    return 1
  fi
  if [[ -f "$PENDING_XRAY_CONFIG" ]] && { [[ ! -x "$XRAY" ]] || ! "$XRAY" run -test -c "$PENDING_XRAY_CONFIG" > >(bounded_logger "$ERROR_FILE") 2>&1; }; then
    return 1
  fi
  /bin/rm -f "$ROLLBACK_CONFIG" "$ROLLBACK_XRAY_CONFIG"
  local had_previous=false
  if [[ -f "$CONFIG_FILE" ]]; then
    /usr/bin/install -m 600 "$CONFIG_FILE" "$ROLLBACK_CONFIG"
    if [[ -f "$XRAY_CONFIG_FILE" ]]; then /usr/bin/install -m 600 "$XRAY_CONFIG_FILE" "$ROLLBACK_XRAY_CONFIG"; fi
    had_previous=true
  fi
  install_config "$PENDING_CONFIG" || return 1
  /bin/rm -f "$PENDING_CONFIG"
  if [[ -f "$PENDING_XRAY_CONFIG" ]]; then
    /usr/bin/install -m 600 "$PENDING_XRAY_CONFIG" "$XRAY_CONFIG_FILE"
    /bin/rm -f "$PENDING_XRAY_CONFIG"
  else
    /bin/rm -f "$XRAY_CONFIG_FILE"
  fi
  publish_config_hash || return 1
  if [[ "$(desired_state)" == "on" ]]; then
    stop_child
    if start_child; then
      /bin/rm -f "$ROLLBACK_CONFIG" "$ROLLBACK_XRAY_CONFIG"
      return 0
    fi
    log_event "new configuration failed; restoring the previous configuration"
    if [[ "$had_previous" == true ]]; then
      install_config "$ROLLBACK_CONFIG" || return 1
      if [[ -f "$ROLLBACK_XRAY_CONFIG" ]]; then
        /usr/bin/install -m 600 "$ROLLBACK_XRAY_CONFIG" "$XRAY_CONFIG_FILE"
      else
        /bin/rm -f "$XRAY_CONFIG_FILE"
      fi
      publish_config_hash || return 1
      /bin/rm -f "$ROLLBACK_CONFIG"
      /bin/rm -f "$ROLLBACK_XRAY_CONFIG"
      stop_child
      start_child || true
    else
      /bin/rm -f "$CONFIG_FILE" "$XRAY_CONFIG_FILE" "$CONTROL_DIR/config-sha256"
    fi
    return 1
  else
    /bin/rm -f "$ROLLBACK_CONFIG" "$ROLLBACK_XRAY_CONFIG"
    write_status "stopped"
  fi
}

network_signature() {
  local route_info interface gateway address
  interface="$(/usr/sbin/scutil --nwi 2>/dev/null | /usr/bin/awk '$2 == ":" && $3 == "flags" && $1 !~ /^utun/ { print $1; exit }')"
  if [[ -n "$interface" ]]; then
    route_info="$(/sbin/route -n get -ifscope "$interface" default 2>/dev/null || true)"
  else
    route_info="$(/sbin/route -n get default 2>/dev/null || true)"
    interface="$(/usr/bin/awk '/interface:/{print $2; exit}' <<< "$route_info")"
  fi
  gateway="$(/usr/bin/awk '/gateway:/{print $2; exit}' <<< "$route_info")"
  address="$(/usr/sbin/ipconfig getifaddr "$interface" 2>/dev/null || true)"
  if [[ -n "$interface" ]]; then
    /usr/bin/printf '%s|%s|%s\n' "$interface" "$gateway" "$address"
  else
    /usr/bin/printf 'offline\n'
  fi
}

default_route_signature() {
  local route_info interface gateway
  route_info="$(/sbin/route -n get default 2>/dev/null || true)"
  interface="$(/usr/bin/awk '/interface:/{print $2; exit}' <<< "$route_info")"
  gateway="$(/usr/bin/awk '/gateway:/{print $2; exit}' <<< "$route_info")"
  if [[ -n "$interface" ]]; then
    /usr/bin/printf '%s|%s\n' "$interface" "${gateway:-link}"
  else
    /usr/bin/printf 'unavailable\n'
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
  start_with_limit || true
}

start_with_limit() {
  if start_child; then
    START_FAILURES=0
    return 0
  fi
  START_FAILURES=$((START_FAILURES + 1))
  log_event "VPN start failed ($START_FAILURES/$MAX_START_FAILURES)"
  if [[ "$START_FAILURES" -ge "$MAX_START_FAILURES" ]]; then
    set_desired "off"
    write_status "error: retry limit reached"
    log_event "VPN disabled after reaching the startup retry limit"
  fi
  return 1
}

run_watchdog() {
  local now gap signature default_route recovered=false
  now="$(/bin/date +%s)"
  gap=$((now - LAST_TICK))

  if [[ "$gap" -gt "$WATCHDOG_GAP_SECONDS" ]] && runtime_running; then
    recover_child "sleep or a scheduler pause"
    recovered=true
  fi

  if [[ $((now - LAST_NETWORK_CHECK)) -ge 5 ]]; then
    signature="$(network_signature)"
    default_route="$(default_route_signature)"
    if [[ -n "$LAST_DEFAULT_ROUTE_SIGNATURE" && "$default_route" != "$LAST_DEFAULT_ROUTE_SIGNATURE" ]]; then
      log_event "default route changed: $LAST_DEFAULT_ROUTE_SIGNATURE -> $default_route"
    fi
    LAST_DEFAULT_ROUTE_SIGNATURE="$default_route"
    if [[ -n "$LAST_NETWORK_SIGNATURE" && "$signature" != "$LAST_NETWORK_SIGNATURE" && "$signature" != "offline" ]] && runtime_running; then
      log_event "physical network changed: $LAST_NETWORK_SIGNATURE -> $signature"
      recover_child "a network interface change"
      recovered=true
    fi
    LAST_NETWORK_SIGNATURE="$signature"
    LAST_NETWORK_CHECK="$now"

    if tunnel_ready; then
      TUN_MISSES=0
    else
      TUN_MISSES=$((TUN_MISSES + 1))
      if [[ "$TUN_MISSES" -ge 2 ]] && runtime_running; then
        recover_child "the TUN interface disappeared"
        TUN_MISSES=0
        recovered=true
      fi
    fi
  fi
  if child_running && [[ -f "$XRAY_CONFIG_FILE" ]] && ! xray_running; then
    recover_child "the Xray transport stopped"
    recovered=true
  fi

  if [[ "$recovered" == true ]]; then
    LAST_NETWORK_SIGNATURE="$(network_signature)"
    LAST_DEFAULT_ROUTE_SIGNATURE="$(default_route_signature)"
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
      START_FAILURES=0
      if start_with_limit; then write_response "$token" "ok"; else write_response "$token" "error"; fi
      ;;
    off)
      set_desired "off"
      stop_child
      write_response "$token" "ok"
      ;;
    restart)
      set_desired "on"
      START_FAILURES=0
      stop_child
      if start_with_limit; then write_response "$token" "ok"; else write_response "$token" "error"; fi
      ;;
    reload)
      if reload_config; then write_response "$token" "ok"; else write_response "$token" "error"; fi
      ;;
    reset)
      set_desired "off"
      stop_child
      /bin/rm -f "$CONFIG_FILE" "$XRAY_CONFIG_FILE" "$ROLLBACK_CONFIG" "$ROLLBACK_XRAY_CONFIG" "$PENDING_CONFIG" "$PENDING_XRAY_CONFIG" "$CONTROL_DIR/config-sha256" "$CONTROL_DIR/last-error.log"
      write_response "$token" "ok"
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
publish_config_hash

if [[ "$(desired_state)" == "on" ]]; then
  start_with_limit || true
else
  if [[ -x "$DNS_MANAGER" ]]; then "$DNS_MANAGER" restore > >(bounded_logger "$LOG_FILE") 2> >(bounded_logger "$ERROR_FILE") || true; fi
  write_status "stopped"
fi
LAST_NETWORK_SIGNATURE="$(network_signature)"
LAST_DEFAULT_ROUTE_SIGNATURE="$(default_route_signature)"
log_event "network state: physical=$LAST_NETWORK_SIGNATURE default=$LAST_DEFAULT_ROUTE_SIGNATURE DNS=$(dns_policy)"
LAST_NETWORK_CHECK="$(/bin/date +%s)"

while true; do
  if [[ -f "$COMMAND_FILE" ]]; then
    process_command
  fi
  if [[ "$(desired_state)" == "on" ]] && ! child_running; then
    start_with_limit || true
  fi
  if [[ "$(desired_state)" == "on" ]]; then
    run_watchdog
  else
    LAST_TICK="$(/bin/date +%s)"
  fi
  NOW="$(/bin/date +%s)"
  if [[ $((NOW - LAST_STATUS_PUBLISH)) -ge 2 ]]; then
    if child_running; then write_status "running"; fi
    LAST_STATUS_PUBLISH="$NOW"
  fi
  /bin/sleep 0.5
done

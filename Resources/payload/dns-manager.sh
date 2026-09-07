#!/bin/bash

set -euo pipefail

ACTION="${1:-}"
BASE_DIR="${MATVEEV_BASE_DIR:-/Library/Application Support/matveevVpn}"
RUN_DIR="$BASE_DIR/run"
STATE_FILE="$RUN_DIR/dns-state"
NETWORKSETUP="${MATVEEV_NETWORKSETUP:-/usr/sbin/networksetup}"
ROUTE="${MATVEEV_ROUTE:-/sbin/route}"
SCUTIL="${MATVEEV_SCUTIL:-/usr/sbin/scutil}"
TUN_DNS="${MATVEEV_TUN_DNS:-198.18.0.2}"

log_event() {
  /usr/bin/printf '%s dns-manager: %s\n' "$(/bin/date '+%Y-%m-%d %H:%M:%S')" "$1" >&2
}

active_interface() {
  if [[ -n "${MATVEEV_DEFAULT_INTERFACE:-}" ]]; then
    /usr/bin/printf '%s\n' "$MATVEEV_DEFAULT_INTERFACE"
    return
  fi
  local interface
  interface="$("$SCUTIL" --nwi 2>/dev/null | /usr/bin/awk '$2 == ":" && $3 == "flags" && $1 !~ /^utun/ { print $1; exit }')"
  if [[ -n "$interface" ]]; then
    /usr/bin/printf '%s\n' "$interface"
    return
  fi
  interface="$("$ROUTE" -n get default 2>/dev/null | /usr/bin/awk '/interface:/{print $2; exit}')"
  [[ "$interface" == utun* ]] || /usr/bin/printf '%s\n' "$interface"
}

network_service_for_interface() {
  local interface="$1"
  "$NETWORKSETUP" -listnetworkserviceorder | /usr/bin/awk -v target="$interface" '
    /^\([0-9]+\)/ {
      service=$0
      sub(/^\([0-9]+\)[[:space:]]*/, "", service)
      sub(/^\*/, "", service)
      next
    }
    /Device:/ {
      device=$0
      sub(/^.*Device:[[:space:]]*/, "", device)
      sub(/\).*$/, "", device)
      if (device == target) { print service; exit }
    }
  '
}

valid_ip() {
  /usr/bin/ruby -ripaddr -e 'IPAddr.new(ARGV.fetch(0))' "$1" >/dev/null 2>&1
}

save_state() {
  local service="$1" current line mode="automatic" temporary
  current="$("$NETWORKSETUP" -getdnsservers "$service" 2>/dev/null || true)"
  temporary="$(/usr/bin/mktemp "$RUN_DIR/.dns-state.XXXXXX")"
  /usr/bin/printf '%s\n%s\n' "$service" "$mode" > "$temporary"
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    if valid_ip "$line"; then
      if [[ "$mode" == "automatic" ]]; then
        mode="manual"
        /usr/bin/sed -i '' '2s/.*/manual/' "$temporary"
      fi
      /usr/bin/printf '%s\n' "$line" >> "$temporary"
    fi
  done <<< "$current"
  /bin/chmod 600 "$temporary"
  /bin/mv -f "$temporary" "$STATE_FILE"
}

service_exists() {
  local expected="$1" service
  while IFS= read -r service; do
    service="${service#\*}"
    [[ "$service" == "$expected" ]] && return 0
  done < <("$NETWORKSETUP" -listallnetworkservices 2>/dev/null | /usr/bin/tail -n +2)
  return 1
}

restore_state() {
  [[ -f "$STATE_FILE" ]] || return 0
  local service mode attempt restored=false
  local -a servers=()
  service="$(/usr/bin/sed -n '1p' "$STATE_FILE")"
  mode="$(/usr/bin/sed -n '2p' "$STATE_FILE")"
  while IFS= read -r server; do
    [[ -n "$server" ]] && valid_ip "$server" && servers+=("$server")
  done < <(/usr/bin/tail -n +3 "$STATE_FILE")

  if [[ -z "$service" || "$service" == *$'\n'* || "$mode" != "automatic" && "$mode" != "manual" ]]; then
    log_event "discarding invalid saved DNS state"
    /bin/rm -f "$STATE_FILE"
    return 1
  fi
  if ! service_exists "$service"; then
    log_event "saved network service no longer exists: $service"
    /bin/rm -f "$STATE_FILE"
    return 0
  fi
  if [[ "$mode" == "manual" && "${#servers[@]}" -eq 0 ]]; then
    log_event "discarding invalid manual DNS state"
    /bin/rm -f "$STATE_FILE"
    return 1
  fi

  for attempt in 1 2 3; do
    if [[ "$mode" == "automatic" ]]; then
      if "$NETWORKSETUP" -setdnsservers "$service" Empty >/dev/null 2>&1; then restored=true; break; fi
    else
      if "$NETWORKSETUP" -setdnsservers "$service" "${servers[@]}" >/dev/null 2>&1; then restored=true; break; fi
    fi
    /bin/sleep 0.2
  done
  [[ "$restored" == true ]] || return 1
  /bin/rm -f "$STATE_FILE"
  /usr/bin/dscacheutil -flushcache >/dev/null 2>&1 || true
  /usr/bin/killall -HUP mDNSResponder >/dev/null 2>&1 || true
  log_event "restored DNS for $service"
}

apply_dns() {
  /bin/mkdir -p "$RUN_DIR"
  local interface service saved_service
  interface="$(active_interface)"
  [[ -n "$interface" ]] || { log_event "could not determine the default interface"; return 1; }
  service="$(network_service_for_interface "$interface")"
  [[ -n "$service" ]] || { log_event "could not map $interface to a network service"; return 1; }

  if [[ -f "$STATE_FILE" ]]; then
    saved_service="$(/usr/bin/sed -n '1p' "$STATE_FILE")"
    if [[ "$saved_service" != "$service" ]]; then
      restore_state || return 1
    fi
  fi
  [[ -f "$STATE_FILE" ]] || save_state "$service"

  if ! "$NETWORKSETUP" -setdnsservers "$service" "$TUN_DNS" >/dev/null 2>&1; then
    restore_state || true
    log_event "could not set tunnel DNS for $service"
    return 1
  fi
  /usr/bin/dscacheutil -flushcache >/dev/null 2>&1 || true
  /usr/bin/killall -HUP mDNSResponder >/dev/null 2>&1 || true
  log_event "using tunnel DNS $TUN_DNS for $service"
}

case "$ACTION" in
  apply) apply_dns ;;
  restore) restore_state ;;
  *) echo "usage: dns-manager.sh apply|restore" >&2; exit 2 ;;
esac

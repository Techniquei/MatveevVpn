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
START_RETRY_SECONDS="${MATVEEV_START_RETRY_SECONDS:-30}"

CHILD_PID=""
XRAY_PID=""
LAST_TICK=0
LAST_NETWORK_CHECK=0
LAST_NETWORK_SIGNATURE=""
LAST_DEFAULT_ROUTE_SIGNATURE=""
TUN_MISSES=0
LAST_STATUS_PUBLISH=0
LAST_WAKE_SIGNATURE=""
DNS_CONFIGURED=false
READINESS_STATUS="starting"
VPN_DNS_READY=false
DIRECT_DNS_READY=false
DNS_MISSES=0
START_FAILURES=0
NEXT_START_ATTEMPT=0

/bin/mkdir -p "$CONTROL_DIR" "$RUN_DIR"

bounded_log_line() {
  printf '%s\n' "$2" | bounded_logger "$1"
}

bounded_logger() {
  # Keep one writer per engine stream: spawning utilities for every INFO line
  # fills the output pipe and blocks the engine itself during DNS/traffic bursts.
  /usr/bin/ruby -e '
    require "tempfile"
    file, control, limit_text = ARGV
    limit = Integer(limit_text)
    abort "invalid log limit" unless limit > 0
    STDIN.binmode
    lock = nil
    STDIN.each_line do |line|
      lock ||= File.open(file + ".lock", File::RDWR | File::CREAT, 0600)
      line += "\n" unless line.end_with?("\n")
      entry = line.bytesize > limit ? line.byteslice(-limit, limit) : line
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 5
      until lock.flock(File::LOCK_EX | File::LOCK_NB)
        exit 1 if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
        sleep 0.01
      end
      begin
        File.open(file, File::RDWR | File::CREAT, 0600) do |log|
          log.chmod(0600)
          size = log.stat.size
          if size + entry.bytesize > limit
            # Leave headroom so a full log is not copied again for every line.
            keep = [size, [limit * 9 / 10 - entry.bytesize, 0].max].min
            log.seek(size - keep)
            retained = keep > 0 ? log.read(keep) : ""
            Tempfile.create([".bounded-log.", ""], File.dirname(file)) do |temporary|
              temporary.binmode
              temporary.write(retained)
              temporary.write(entry)
              temporary.close
              File.rename(temporary.path, file)
            end
          else
            log.seek(0, IO::SEEK_END)
            log.write(entry)
          end
        end
      ensure
        lock.flock(File::LOCK_UN)
      end
      # sing-box 1.14 emits these only after a download or HTTP 304 succeeds.
      if line.match?(/INFO.*router: (updated rule-set preset-[a-z0-9-]+|update rule-set preset-[a-z0-9-]+: not modified)\s*\z/)
        Tempfile.create([".routing-update.", ""], control) do |temporary|
          temporary.write("#{Time.now.to_i}\n")
          temporary.chmod(0644)
          temporary.close
          File.rename(temporary.path, File.join(control, "routing-updated-at"))
        end
      end
    end
  ' "$1" "$CONTROL_DIR" "$MAX_LOG_BYTES"
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

record_unexpected_exit() {
  local process_name="$1" pid="$2" exit_status
  if wait "$pid" 2>/dev/null; then
    exit_status=0
  else
    exit_status=$?
  fi
  bounded_log_line "$ERROR_FILE" "$(/bin/date '+%Y-%m-%d %H:%M:%S') controller: $process_name exited unexpectedly (pid=$pid, status=$exit_status)"
  write_status "recovering"
  publish_recent_errors || true
}

write_status() {
  local value="$1"
  READINESS_STATUS="$value"
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
  if [[ "$value" != "ok" && "$value" != "pending" ]]; then publish_recent_errors || true; fi
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
  "${MATVEEV_IFCONFIG:-/sbin/ifconfig}" 2>/dev/null | /usr/bin/awk '
    /^[A-Za-z0-9]+:/ { interface=$1; sub(":", "", interface) }
    /inet 198\.18\.0\.1 / { print interface; exit }
  '
}

log_event() {
  local message="$(/bin/date '+%Y-%m-%d %H:%M:%S') controller: $1"
  if [[ -n "${2:-}" ]]; then
    message="$message; duration_ms=$(( $(monotonic_ms) - $2 ))"
    # Include lifecycle timings in the existing exported runtime diagnostics.
    bounded_log_line "$ERROR_FILE" "$message"
  fi
  bounded_log_line "$LOG_FILE" "$message"
}

monotonic_ms() {
  /usr/bin/ruby -e 'puts Process.clock_gettime(Process::CLOCK_MONOTONIC, :millisecond)'
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

routing_mode() {
  /usr/bin/ruby -rjson -e '
    config = JSON.parse(File.read(ARGV.fetch(0)))
    puts config.dig("route", "final") == "vpn" ? "all" : "selective"
  ' "$CONFIG_FILE" 2>/dev/null || /usr/bin/printf 'unknown\n'
}

configure_system_dns() {
  [[ -x "$DNS_MANAGER" ]] || return 0
  "$DNS_MANAGER" apply > >(bounded_logger "$LOG_FILE") 2> >(bounded_logger "$ERROR_FILE") || return 1
  log_event "DNS policy: system override enabled for $(routing_mode) routing"
}

tunnel_dns_ready() {
  "${MATVEEV_DIG:-/usr/bin/dig}" +time=1 +tries=1 +short @198.18.0.2 "${1:-api4.ipify.org}" A 2>/dev/null |
    /usr/bin/awk '/^([0-9]{1,3}\.){3}[0-9]{1,3}$/ { found=1 } END { exit !found }'
}

check_engine_config() {
  local deadline="$1" checker
  shift
  "$@" > >(bounded_logger "$ERROR_FILE") 2>&1 &
  checker=$!
  while /bin/kill -0 "$checker" 2>/dev/null; do
    if [[ "$(monotonic_ms)" -ge "$deadline" ]]; then
      /bin/kill -KILL "$checker" 2>/dev/null || true
      wait "$checker" 2>/dev/null || true
      return 1
    fi
    /bin/sleep 0.05
  done
  wait "$checker"
}

# Every publication of running uses this result, including an already-live runtime.
# Both probes have explicit DNS routing rules, including in All Traffic mode.
check_runtime_readiness() {
  local deadline="${1:-$(( $(monotonic_ms) + 2500 ))}"
  if ! runtime_running || ! tunnel_ready || [[ "$DNS_CONFIGURED" != true ]]; then
    READINESS_STATUS="starting"
    return 1
  fi
  if ! physical_network_ready; then READINESS_STATUS="waiting for network"; return 1; fi
  # Keep the previous diagnosis if the budget cannot fit another pair of probes.
  [[ $(( $(monotonic_ms) + 2000 )) -le "$deadline" ]] || return 1
  VPN_DNS_READY=false
  DIRECT_DNS_READY=false
  READINESS_STATUS="starting"
  if tunnel_dns_ready; then VPN_DNS_READY=true; fi
  if tunnel_dns_ready api64.ipify.org; then DIRECT_DNS_READY=true; fi
  # A process or TUN can disappear during a blocking DNS query.
  runtime_running && tunnel_ready || return 1
  [[ "$(monotonic_ms)" -le "$deadline" ]] || return 1
  if [[ "$VPN_DNS_READY" == true && "$DIRECT_DNS_READY" == true ]]; then
    READINESS_STATUS="running"
    return 0
  elif [[ "$VPN_DNS_READY" == true ]]; then
    READINESS_STATUS="waiting for direct DNS"
  elif [[ "$DIRECT_DNS_READY" == true ]]; then
    READINESS_STATUS="waiting for VPN DNS"
  else
    READINESS_STATUS="waiting for network"
  fi
  return 1
}

start_child() {
  local started="$(monotonic_ms)"
  local deadline="${1:-$((started + 10000))}"
  if [[ "${operation_deadline:-$deadline}" -lt "$deadline" ]]; then deadline="$operation_deadline"; fi
  if [[ "$started" -ge "$deadline" ]]; then write_status "error"; return 1; fi
  if [[ ! -x "$SING_BOX" || ! -f "$CONFIG_FILE" ]]; then write_status "error"; return 1; fi
  # Boot/DHCP delay is normal. Do not create a TUN or alter DNS before a
  # physical IPv4 address and scoped default route exist.
  if ! physical_network_ready; then write_status "waiting for network"; return 1; fi
  if ! runtime_running; then
    if child_running || xray_running; then stop_child "$deadline" recovering; fi
    write_status "starting"
    if ! check_engine_config "$deadline" "$SING_BOX" check -c "$CONFIG_FILE"; then
      write_status "error"
      return 1
    fi
    if [[ -f "$XRAY_CONFIG_FILE" ]]; then
      if [[ ! -x "$XRAY" ]] || ! check_engine_config "$deadline" "$XRAY" run -test -c "$XRAY_CONFIG_FILE"; then
        write_status "error"
        return 1
      fi
      "$XRAY" run -c "$XRAY_CONFIG_FILE" > >(bounded_logger "$LOG_FILE") 2> >(bounded_logger "$ERROR_FILE") &
      XRAY_PID=$!
      /usr/bin/printf '%s\n' "$XRAY_PID" > "$XRAY_PID_FILE"
    fi
    "$SING_BOX" run -c "$CONFIG_FILE" > >(bounded_logger "$LOG_FILE") 2> >(bounded_logger "$ERROR_FILE") &
    CHILD_PID=$!
    /usr/bin/printf '%s\n' "$CHILD_PID" > "$PID_FILE"
  fi
  local ready_attempt
  for ready_attempt in {1..30}; do
    [[ "$(monotonic_ms)" -lt "$deadline" ]] || break
    runtime_running || break
    if tunnel_ready; then
      log_event "runtime launch: TUN ready" "$started"
      local dns_started="$(monotonic_ms)"
      if [[ "$DNS_CONFIGURED" != true ]]; then
        if ! configure_system_dns; then
          if ! physical_network_ready; then write_status "waiting for network"; return 1; fi
          log_event "could not apply the DNS policy"
          stop_child "$deadline" recovering
          write_status "error"
          return 1
        fi
        DNS_CONFIGURED=true
      fi
      local dns_attempt
      for dns_attempt in {1..8}; do
        [[ $(( $(monotonic_ms) + 2000 )) -le "$deadline" ]] || break
        if check_runtime_readiness "$deadline"; then
          DNS_MISSES=0
          log_event "tunnel DNS is ready on VPN and direct paths after $dns_attempt check(s)" "$dns_started"
          write_status "$READINESS_STATUS"
          return 0
        fi
        runtime_running && tunnel_ready || break
        # Preserve a working VPN when only direct DNS is unavailable.
        if [[ "$READINESS_STATUS" == "waiting for direct DNS" ]]; then
          log_event "startup DNS: direct DNS unavailable; VPN DNS ready" "$dns_started"
          write_status "$READINESS_STATUS"
          return 1
        fi
        /bin/sleep 0.25
      done
      if runtime_running && [[ "$READINESS_STATUS" == "waiting for network" ]]; then
        log_event "startup DNS: waiting for network" "$dns_started"
        write_status "$READINESS_STATUS"
        return 1
      fi
      log_event "VPN DNS did not become ready before the startup deadline" "$dns_started"
      stop_child "$deadline" recovering
      write_status "error"
      return 1
    fi
    /bin/sleep 0.2
  done
  log_event "runtime launch did not become ready" "$started"
  stop_child "$deadline" recovering
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
  local started="$(monotonic_ms)"
  local final_status="${2:-stopped}"
  write_status "$final_status"
  local deadline=$((started + 5000))
  # Failed startup cleanup must not consume the caller's rollback reserve.
  if [[ "${1:-$deadline}" -lt "$deadline" ]]; then deadline="$1"; fi
  if [[ "${operation_deadline:-$deadline}" -lt "$deadline" ]]; then deadline="$operation_deadline"; fi
  local owned_interface
  owned_interface="$(tunnel_interface)"
  if [[ -x "$DNS_MANAGER" ]]; then
    "$DNS_MANAGER" restore > >(bounded_logger "$LOG_FILE") 2> >(bounded_logger "$ERROR_FILE") || log_event "could not restore system DNS"
  fi
  # Both engines get the same five-second grace concurrently.
  if child_running; then /bin/kill -TERM "$CHILD_PID" 2>/dev/null || true; fi
  if xray_running; then /bin/kill -TERM "$XRAY_PID" 2>/dev/null || true; fi
  local attempt
  for attempt in {1..50}; do
    child_running || xray_running || break
    [[ "$(monotonic_ms)" -lt "$deadline" ]] || break
    /bin/sleep 0.1
  done
  if child_running; then /bin/kill -KILL "$CHILD_PID" 2>/dev/null || true; fi
  if xray_running; then /bin/kill -KILL "$XRAY_PID" 2>/dev/null || true; fi
  if [[ -n "$CHILD_PID" ]]; then wait "$CHILD_PID" 2>/dev/null || true; fi
  if [[ -n "$XRAY_PID" ]]; then wait "$XRAY_PID" 2>/dev/null || true; fi
  CHILD_PID=""
  /bin/rm -f "$PID_FILE"
  XRAY_PID=""
  /bin/rm -f "$XRAY_PID_FILE"
  if [[ -z "${MATVEEV_BASE_DIR:-}" && -n "$owned_interface" ]]; then
    cleanup_tunnel_state "$owned_interface"
  fi
  DNS_CONFIGURED=false
  DNS_MISSES=0
  READINESS_STATUS="$final_status"
  write_status "$final_status"
  log_event "runtime stop: processes and DNS restored" "$started"
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
  local deadline="${operation_deadline:-$(( $(monotonic_ms) + 10000 ))}"
  if [[ ! -f "$PENDING_CONFIG" || -L "$PENDING_CONFIG" || -L "$PENDING_XRAY_CONFIG" ]]; then
    return 1
  fi
  if ! check_engine_config "$deadline" "$SING_BOX" check -c "$PENDING_CONFIG"; then
    return 1
  fi
  if [[ -f "$PENDING_XRAY_CONFIG" ]] && { [[ ! -x "$XRAY" ]] || ! check_engine_config "$deadline" "$XRAY" run -test -c "$PENDING_XRAY_CONFIG"; }; then
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
    stop_child "${operation_deadline:-$(( $(monotonic_ms) + 5000 ))}" recovering
    # Reserve half the remaining command budget for rollback of a rejected runtime.
    local now="$(monotonic_ms)"
    local attempt_deadline=$((now + (${operation_deadline:-$((now + 20000))} - now) / 2))
    if start_child "$attempt_deadline"; then
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
      stop_child "${operation_deadline:-$(( $(monotonic_ms) + 5000 ))}" recovering
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
  if [[ -n "${MATVEEV_NETWORK_PROBE:-}" ]]; then "$MATVEEV_NETWORK_PROBE"; return; fi
  interface="$(/usr/sbin/scutil --nwi 2>/dev/null | /usr/bin/awk '$2 == ":" && $3 == "flags" && $1 !~ /^utun/ && index($0, "(IPv4") { print $1; exit }')"
  if [[ -n "$interface" ]]; then
    route_info="$(/sbin/route -n get -ifscope "$interface" default 2>/dev/null || true)"
  else
    route_info="$(/sbin/route -n get default 2>/dev/null || true)"
    interface="$(/usr/bin/awk '/interface:/{print $2; exit}' <<< "$route_info")"
  fi
  gateway="$(/usr/bin/awk '/gateway:/{print $2; exit}' <<< "$route_info")"
  address="$(/usr/sbin/ipconfig getifaddr "$interface" 2>/dev/null || true)"
  if [[ -n "$interface" && "$interface" != utun* && -n "$gateway" && -n "$address" && "$address" != 169.254.* ]]; then
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

physical_network_ready() {
  [[ "$(network_signature)" != "offline" ]]
}

wake_signature() {
  # Compare the kernel timeval, excluding its local date/time rendering.
  "${MATVEEV_SYSCTL:-/usr/sbin/sysctl}" -n kern.waketime 2>/dev/null | /usr/bin/sed 's/ }.*$/ }/' || true
}

tunnel_ready() {
  [[ -n "$(tunnel_interface)" ]]
}

recover_child() {
  local reason="$1"
  log_event "restarting VPN after $reason"
  stop_child "$(( $(monotonic_ms) + 5000 ))" recovering
  NEXT_START_ATTEMPT=0
  start_with_retry || true
}

start_with_retry() {
  local now
  now="$(/bin/date +%s)"
  if [[ "$now" -lt "$NEXT_START_ATTEMPT" ]]; then
    return 1
  fi
  if start_child; then
    START_FAILURES=0
    NEXT_START_ATTEMPT=0
    return 0
  fi
  now="$(/bin/date +%s)"
  if [[ "$(/usr/bin/head -n 1 "$STATUS_FILE")" == "waiting for network" || "$(/usr/bin/head -n 1 "$STATUS_FILE")" == "waiting for direct DNS" ]]; then
    NEXT_START_ATTEMPT=$((now + 5))
    return 1
  fi
  START_FAILURES=$((START_FAILURES + 1))
  NEXT_START_ATTEMPT=$((now + START_RETRY_SECONDS))
  write_status "waiting to retry"
  log_event "VPN start failed (attempt $START_FAILURES); retrying in $START_RETRY_SECONDS seconds"
  return 1
}

run_watchdog() {
  local now tick gap wake signature default_route recovered=false
  now="$(/bin/date +%s)"
  tick="$(monotonic_ms)"
  gap=$((tick - LAST_TICK))
  wake="$(wake_signature)"
  # kern.waketime changes even if sleep/wake occurred inside a blocking
  # startup or command. The loop gap measures only time outside our work.
  if [[ -n "$wake" && -n "$LAST_WAKE_SIGNATURE" && "$wake" != "$LAST_WAKE_SIGNATURE" ]] && runtime_running; then
    recover_child "system wake"
    recovered=true
  elif [[ "$LAST_TICK" -gt 0 && "$gap" -gt $((WATCHDOG_GAP_SECONDS * 1000)) ]] && runtime_running; then
    recover_child "a scheduler pause"
    recovered=true
  fi
  LAST_WAKE_SIGNATURE="$wake"

  if [[ $((now - LAST_NETWORK_CHECK)) -ge 5 ]]; then
    signature="$(network_signature)"
    default_route="$(default_route_signature)"
    if [[ -n "$LAST_DEFAULT_ROUTE_SIGNATURE" && "$default_route" != "$LAST_DEFAULT_ROUTE_SIGNATURE" ]]; then
      log_event "default route changed: $LAST_DEFAULT_ROUTE_SIGNATURE -> $default_route"
    fi
    LAST_DEFAULT_ROUTE_SIGNATURE="$default_route"
    if [[ -n "$LAST_NETWORK_SIGNATURE" && "$signature" != "$LAST_NETWORK_SIGNATURE" && "$signature" != "offline" ]]; then
      log_event "physical network changed: $LAST_NETWORK_SIGNATURE -> $signature"
      if runtime_running && [[ "$recovered" == false ]]; then
        recover_child "a network interface change"
        recovered=true
      else
        NEXT_START_ATTEMPT=0
        log_event "physical network became available; retrying VPN immediately"
      fi
    fi
    LAST_NETWORK_SIGNATURE="$signature"
    LAST_NETWORK_CHECK="$now"

    if runtime_running && [[ "$recovered" == false ]]; then
      if tunnel_ready; then
        TUN_MISSES=0
        if [[ "$DNS_CONFIGURED" != true ]] && physical_network_ready; then
          if configure_system_dns; then DNS_CONFIGURED=true; fi
        fi
        check_runtime_readiness || true
        if [[ "$READINESS_STATUS" == "running" ]]; then
          if [[ "$(/usr/bin/head -n 1 "$STATUS_FILE")" != running ]]; then log_event "tunnel DNS is ready after network recovery on VPN and direct paths"; fi
          START_FAILURES=0
          NEXT_START_ATTEMPT=0
          DNS_MISSES=0
        elif [[ "$READINESS_STATUS" == "waiting for VPN DNS" ]]; then
          DNS_MISSES=$((DNS_MISSES + 1))
          if [[ "$DNS_MISSES" -ge 3 ]]; then
            recover_child "VPN DNS failures with working direct DNS"
            recovered=true
          fi
        else
          DNS_MISSES=0
        fi
        if [[ "$recovered" == false ]]; then write_status "$READINESS_STATUS"; fi
      else
        TUN_MISSES=$((TUN_MISSES + 1))
        READINESS_STATUS="recovering"
        write_status "$READINESS_STATUS"
        if [[ "$TUN_MISSES" -ge 2 ]]; then
          recover_child "the TUN interface disappeared"
          TUN_MISSES=0
          recovered=true
        fi
      fi
    fi
  fi
  if child_running && [[ -f "$XRAY_CONFIG_FILE" ]] && ! xray_running && [[ "$recovered" == false ]]; then
    record_unexpected_exit "xray" "$XRAY_PID"
    XRAY_PID=""
    /bin/rm -f "$XRAY_PID_FILE"
    recover_child "the Xray transport stopped"
    recovered=true
  fi

  if [[ "$recovered" == true ]]; then
    LAST_NETWORK_SIGNATURE="$(network_signature)"
    LAST_DEFAULT_ROUTE_SIGNATURE="$(default_route_signature)"
    LAST_NETWORK_CHECK="$(/bin/date +%s)"
    TUN_MISSES=0
  fi
}

process_command() {
  local action=""
  local token=""
  local expiry=""
  read -r action token expiry < "$COMMAND_FILE" || true
  /bin/rm -f "$COMMAND_FILE"
  if [[ ! "$token" =~ ^[A-Za-z0-9._-]+$ ]]; then
    return 0
  fi
  if [[ ! "$expiry" =~ ^[0-9]{13}$ ]]; then write_response "$token" "error"; return 0; fi
  # Convert the client's absolute expiry to our monotonic clock; reserve a second
  # for publishing the acknowledgement and the app's private settings commit.
  local remaining="$(/usr/bin/ruby -e 'puts [[ARGV[0].to_i - (Time.now.to_f * 1000).to_i - 1000, 0].max, 14000].min' "$expiry")"
  local operation_deadline=$(( $(monotonic_ms) + remaining ))
  if [[ "$remaining" -eq 0 ]]; then write_response "$token" "error"; return 0; fi

  case "$action" in
    on)
      set_desired "on"
      START_FAILURES=0
      NEXT_START_ATTEMPT=0
      if start_with_retry; then
        write_response "$token" "ok"
      elif [[ "$READINESS_STATUS" == "waiting for network" || "$READINESS_STATUS" == "waiting for direct DNS" ]]; then
        # The on request is admitted; readiness continues in the background.
        write_response "$token" "pending"
      else
        write_response "$token" "error"
      fi
      ;;
    off)
      set_desired "off"
      stop_child
      write_response "$token" "ok"
      ;;
    restart)
      set_desired "on"
      START_FAILURES=0
      NEXT_START_ATTEMPT=0
      stop_child "$(( $(monotonic_ms) + 5000 ))" recovering
      if start_with_retry; then
        write_response "$token" "ok"
      elif [[ "$READINESS_STATUS" == "waiting for network" || "$READINESS_STATUS" == "waiting for direct DNS" ]]; then
        # The on request is admitted; readiness continues in the background.
        write_response "$token" "pending"
      else
        write_response "$token" "error"
      fi
      ;;
    reload)
      if reload_config; then write_response "$token" "ok"; else write_response "$token" "error"; fi
      ;;
    reset)
      set_desired "off"
      stop_child
      /bin/rm -f "$CONFIG_FILE" "$XRAY_CONFIG_FILE" "$ROLLBACK_CONFIG" "$ROLLBACK_XRAY_CONFIG" "$PENDING_CONFIG" "$PENDING_XRAY_CONFIG" "$CONTROL_DIR/config-sha256" "$CONTROL_DIR/last-error.log" "$CONTROL_DIR/routing-updated-at"
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
LAST_WAKE_SIGNATURE="$(wake_signature)"

if [[ "$(desired_state)" == "on" ]]; then
  start_with_retry || true
else
  if [[ -x "$DNS_MANAGER" ]]; then "$DNS_MANAGER" restore > >(bounded_logger "$LOG_FILE") 2> >(bounded_logger "$ERROR_FILE") || true; fi
  write_status "stopped"
fi
LAST_NETWORK_SIGNATURE="$(network_signature)"
LAST_DEFAULT_ROUTE_SIGNATURE="$(default_route_signature)"
log_event "network state: physical=$LAST_NETWORK_SIGNATURE default=$LAST_DEFAULT_ROUTE_SIGNATURE routing=$(routing_mode)"
LAST_NETWORK_CHECK="$(/bin/date +%s)"
LAST_TICK="$(monotonic_ms)"

while true; do
  # A queued user command takes precedence over another automatic restart.
  if [[ "$(desired_state)" == "on" ]]; then
    if [[ ! -f "$COMMAND_FILE" ]]; then run_watchdog; fi
  else
    LAST_WAKE_SIGNATURE="$(wake_signature)"
  fi
  if [[ -f "$COMMAND_FILE" ]]; then
    process_command
  fi
  if [[ "$(desired_state)" == "on" && -n "$CHILD_PID" ]] && ! child_running; then
    record_unexpected_exit "sing-box" "$CHILD_PID"
    CHILD_PID=""
    /bin/rm -f "$PID_FILE"
  fi
  if [[ "$(desired_state)" == "on" ]] && ! child_running; then
    start_with_retry || true
  fi
  NOW="$(/bin/date +%s)"
  if [[ $((NOW - LAST_STATUS_PUBLISH)) -ge 2 ]]; then
    # Refresh status freshness without bypassing the latest DNS readiness result.
    if runtime_running; then
      if ! tunnel_ready; then READINESS_STATUS="recovering"; fi
      write_status "$READINESS_STATUS"
    fi
    LAST_STATUS_PUBLISH="$NOW"
  fi
  LAST_TICK="$(monotonic_ms)"
  /bin/sleep 0.5
done

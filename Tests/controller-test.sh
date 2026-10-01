#!/bin/bash

set -euo pipefail

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
RUNTIME="$(/usr/bin/mktemp -d /private/tmp/matveev-controller-test.XXXXXX)"
CONTROL="$RUNTIME/control"
CURRENT_DNS="$RUNTIME/current-dns"
DNS_CALL_LOG="$RUNTIME/dns-calls"

/bin/mkdir -p "$RUNTIME/bin" "$RUNTIME/run" "$CONTROL"
/bin/cp "$TEST_DIR/fake-sing-box" "$RUNTIME/bin/sing-box"
/bin/cp "$TEST_DIR/fake-xray" "$RUNTIME/bin/xray"
/bin/cp "$TEST_DIR/fake-networksetup" "$RUNTIME/bin/networksetup"
/bin/cp "$TEST_DIR/fake-dig" "$RUNTIME/bin/dig"
/bin/cp "$TEST_DIR/fake-ifconfig" "$RUNTIME/bin/ifconfig"
/bin/cp "$TEST_DIR/../Resources/payload/dns-manager.sh" "$RUNTIME/bin/dns-manager.sh"
/bin/cp "$TEST_DIR/config.json" "$RUNTIME/config.json"
/bin/chmod 755 "$RUNTIME/bin/sing-box" "$RUNTIME/bin/xray" "$RUNTIME/bin/networksetup" "$RUNTIME/bin/dig" "$RUNTIME/bin/ifconfig" "$RUNTIME/bin/dns-manager.sh"
/usr/bin/printf 'on\n' > "$RUNTIME/run/desired-state"
/usr/bin/printf '9.9.9.9\n' > "$CURRENT_DNS"
: > "$DNS_CALL_LOG"
/usr/bin/printf '4\n' > "$RUNTIME/tunnel-delay"
# Seed oversized text logs; binary NUL padding makes grep platform-dependent.
/usr/bin/ruby -e 'ARGV.each { |path| File.write(path, ("x" * 99 + "\n") * 31000) }' "$RUNTIME/vpn.log" "$RUNTIME/vpn.error.log"

MATVEEV_BASE_DIR="$RUNTIME" \
MATVEEV_LOG_FILE="$RUNTIME/vpn.log" \
MATVEEV_ERROR_FILE="$RUNTIME/vpn.error.log" \
MATVEEV_START_RETRY_SECONDS=1 \
MATVEEV_NETWORKSETUP="$RUNTIME/bin/networksetup" \
MATVEEV_DIG="$RUNTIME/bin/dig" \
MATVEEV_IFCONFIG="$RUNTIME/bin/ifconfig" \
MATVEEV_DEFAULT_INTERFACE="test0" \
MATVEEV_FAKE_DNS="$CURRENT_DNS" \
MATVEEV_FAKE_LOG="$DNS_CALL_LOG" \
  "$TEST_DIR/../Resources/payload/controller.sh" &
CONTROLLER_PID=$!

cleanup() {
  /bin/kill -TERM "$CONTROLLER_PID" 2>/dev/null || true
  wait "$CONTROLLER_PID" 2>/dev/null || true
  /bin/rm -rf "$RUNTIME"
}
trap cleanup EXIT
trap 'echo "Controller test failed at line $LINENO: $BASH_COMMAND" >&2; /usr/bin/tail -n 30 "$RUNTIME/vpn.log" "$RUNTIME/vpn.error.log" >&2' ERR

wait_for_file_value() {
  local file="$1"
  local expected="$2"
  local attempt=0
  while [[ "$attempt" -lt 200 ]]; do
    if [[ -f "$file" && "$(/usr/bin/head -n 1 "$file")" == "$expected" ]]; then
      return 0
    fi
    attempt=$((attempt + 1))
    /bin/sleep 0.1
  done
  echo "Timed out waiting for $file = $expected" >&2
  return 1
}

wait_for_file_text() {
  local file="$1"
  local expected="$2"
  local attempt=0
  while [[ "$attempt" -lt 100 ]]; do
    if [[ -f "$file" ]] && /usr/bin/grep -q "$expected" "$file"; then
      return 0
    fi
    attempt=$((attempt + 1))
    /bin/sleep 0.1
  done
  echo "Timed out waiting for $file to contain $expected" >&2
  return 1
}

send_action() {
  local action="$1"
  send_action_expect "$action" "ok"
}

send_action_expect() {
  local action="$1"
  local expected="$2"
  local token="test-$action-$RANDOM"
  local expiry="$(/usr/bin/ruby -e 'puts ((Time.now.to_f + ARGV[0].to_f) * 1000).to_i' -- "${3:-15}")"
  /usr/bin/printf '%s %s %s\n' "$action" "$token" "$expiry" > "$CONTROL/.command-test"
  /bin/mv -f "$CONTROL/.command-test" "$CONTROL/command"
  wait_for_file_value "$CONTROL/response-$token" "$expected"
  LAST_COMMAND_EXPIRY="$expiry"
  LAST_COMMAND_RESPONSE="$CONTROL/response-$token"
}

# Wi-Fi parameters stay the same while Internet connectivity arrives later.
wait_for_file_value "$CONTROL/runtime-status" "waiting for network"
/usr/bin/ruby - "$RUNTIME/vpn.log" <<'RUBY'
lines = File.read(ARGV[0]).lines
launch = lines.grep(/runtime launch: TUN ready;/).last[/duration_ms=(\d+)/, 1].to_i
dns = lines.grep(/startup DNS: waiting for network;/).last[/duration_ms=(\d+)/, 1].to_i
abort 'TUN and DNS still have separate startup budgets' unless launch + dns < 11500
RUBY
/bin/rm "$RUNTIME/tunnel-delay"
BOOT_ENGINE_PID="$(cat "$RUNTIME/run/sing-box.pid")"
[[ "$(cat "$CURRENT_DNS")" == "198.18.0.2" ]]
[[ "$(cat "$RUNTIME/run/desired-state")" == on ]]
/usr/bin/touch "$RUNTIME/network-ready"
wait_for_file_value "$CONTROL/runtime-status" "running"
[[ "$(cat "$RUNTIME/run/sing-box.pid")" == "$BOOT_ENGINE_PID" ]]
[[ ! -f "$CONTROL/routing-updated-at" ]]
/usr/bin/grep -q 'tunnel DNS is ready' "$RUNTIME/vpn.log"
[[ "$(/usr/bin/wc -c < "$RUNTIME/vpn.log" | /usr/bin/tr -d '[:space:]')" -le 3000000 ]]
[[ "$(/usr/bin/wc -c < "$RUNTIME/vpn.error.log" | /usr/bin/tr -d '[:space:]')" -le 3000000 ]]
[[ "$(cat "$CURRENT_DNS")" == "198.18.0.2" ]]
# With working direct DNS, an unavailable VPN node must still fail normally.
send_action off
/usr/bin/touch "$RUNTIME/node-unavailable"
send_action_expect on error
wait_for_file_value "$CONTROL/runtime-status" "waiting to retry"
[[ "$(cat "$CURRENT_DNS")" == "9.9.9.9" ]]
/bin/rm "$RUNTIME/node-unavailable"
send_action on
# A ready engine must reach DNS without the former fixed one-second pause.
/usr/bin/ruby - "$RUNTIME/vpn.log" <<'RUBY'
timing = File.read(ARGV[0]).lines.grep(/runtime launch: TUN ready; duration_ms=/).last
abort 'Ready runtime still waits a full second' unless timing && timing[/duration_ms=(\d+)/, 1].to_i < 1000
RUBY
/usr/bin/grep -Eq 'tunnel DNS is ready.*duration_ms=[0-9]+' "$RUNTIME/vpn.error.log"
send_action off
/usr/bin/grep -Eq 'runtime stop: processes and DNS restored; duration_ms=[0-9]+' "$RUNTIME/vpn.error.log"
/usr/bin/ruby - "$RUNTIME/vpn.log" <<'RUBY'
timing = File.read(ARGV[0]).lines.grep(/runtime stop: processes and DNS restored; duration_ms=/).last
abort 'Exited engine still waits a full second' unless timing && timing[/duration_ms=(\d+)/, 1].to_i < 1000
RUBY
# A slower TUN must be observed before publishing running.
/usr/bin/printf '0.4\n' > "$RUNTIME/tunnel-delay"
send_action on
/usr/bin/ruby - "$RUNTIME/vpn.log" <<'RUBY'
timing = File.read(ARGV[0]).lines.grep(/runtime launch: TUN ready; duration_ms=/).last
abort 'Runtime accepted before TUN readiness' unless timing && timing[/duration_ms=(\d+)/, 1].to_i >= 400
RUBY
/bin/rm "$RUNTIME/tunnel-delay"
# Unexpected runtime exits publish a user-readable snapshot before retrying.
/bin/kill -KILL "$(/usr/bin/head -n 1 "$RUNTIME/run/sing-box.pid")"
wait_for_file_text "$CONTROL/last-error.log" 'sing-box exited unexpectedly'
/usr/bin/grep -Eq 'status=(9|137)' "$CONTROL/last-error.log"
wait_for_file_value "$CONTROL/runtime-status" "running"
send_action off
wait_for_file_value "$CONTROL/runtime-status" "stopped"
[[ "$(cat "$CURRENT_DNS")" == "9.9.9.9" ]]
# INFO traffic must drain without blocking the engine, even across rotation.
/usr/bin/ruby -e '
  File.open(ARGV.fetch(0), "w", 0600) do |file|
    25000.times { |i| file.puts "INFO dns: exchanged A burst-#{i}.example.invalid. 60 IN A 192.0.2.1 #{"x" * 100}" }
    file.puts "INFO dns: log burst drained"
  end
' "$RUNTIME/log-burst"
send_action on
wait_for_file_text "$RUNTIME/vpn.log" 'INFO dns: log burst drained'
[[ "$(/usr/bin/wc -c < "$RUNTIME/vpn.log" | /usr/bin/tr -d '[:space:]')" -le 3000000 ]]
[[ "$(/usr/bin/stat -f '%Lp' "$RUNTIME/vpn.log")" == "600" ]]
[[ ! -f "$CONTROL/routing-updated-at" ]]
send_action off
/bin/rm "$RUNTIME/log-burst"
/usr/bin/printf '%s\n' 'ERROR router: fetch rule-set preset-youtube: timeout' > "$RUNTIME/preset-update-log"
send_action on
wait_for_file_value "$CONTROL/runtime-status" "running"
[[ ! -f "$CONTROL/routing-updated-at" ]]
send_action off
/usr/bin/printf '%s\n' 'INFO router: updated rule-set preset-youtube' > "$RUNTIME/preset-update-log"
send_action on
wait_for_file_text "$CONTROL/routing-updated-at" '^[0-9][0-9]*$'
[[ "$(/usr/bin/stat -f '%Lp' "$CONTROL/routing-updated-at")" == "644" ]]
# A successful conditional check also refreshes the date; failures never do.
/usr/bin/printf '1\n' > "$CONTROL/routing-updated-at"
send_action off
/usr/bin/printf '%s\n' 'INFO router: update rule-set preset-telegram-ip: not modified' > "$RUNTIME/preset-update-log"
send_action on
wait_for_file_text "$CONTROL/routing-updated-at" '^[0-9][0-9][0-9]*$'
[[ "$(cat "$CURRENT_DNS")" == "198.18.0.2" ]]
send_action restart
wait_for_file_value "$CONTROL/runtime-status" "running"
# Selective routing still needs the macOS system DNS override; native TUN DNS
# alone can become intermittently unreachable in sing-box CLI mode.
/usr/bin/printf '{"route":{"final":"direct"}}\n' > "$CONTROL/pending-config.json"
send_action reload
wait_for_file_value "$CONTROL/runtime-status" "running"
[[ "$(cat "$CURRENT_DNS")" == "198.18.0.2" ]]
/usr/bin/grep -q 'system override enabled for selective routing' "$RUNTIME/vpn.log"
# All Traffic uses the same system DNS override.
/bin/cp "$TEST_DIR/config.json" "$CONTROL/pending-config.json"
/usr/bin/printf '{"valid":true}\n' > "$CONTROL/pending-xray.json"
send_action reload
wait_for_file_value "$CONTROL/runtime-status" "running"
[[ "$(cat "$CURRENT_DNS")" == "198.18.0.2" ]]
[[ -f "$RUNTIME/xray.json" && -f "$RUNTIME/run/xray.pid" ]]
# Engines ignoring TERM share one grace period, rather than two sequential waits.
send_action off
/usr/bin/touch "$RUNTIME/ignore-term"
send_action on
send_action off
/usr/bin/ruby - "$RUNTIME/vpn.log" <<'RUBY'
timing = File.read(ARGV[0]).lines.grep(/runtime stop: processes and DNS restored;/).last
abort 'Engine shutdown still waits sequentially' unless timing[/duration_ms=(\d+)/, 1].to_i < 6500
RUBY
[[ "$(cat "$CURRENT_DNS")" == "9.9.9.9" ]]
[[ ! -f "$RUNTIME/run/sing-box.pid" && ! -f "$RUNTIME/run/xray.pid" ]]
/bin/rm "$RUNTIME/ignore-term"
send_action on
# Expired commands must not change desired state or touch the current runtime.
ENGINE_BEFORE_EXPIRY="$(cat "$RUNTIME/run/sing-box.pid")"
send_action_expect off error -1
[[ "$(cat "$RUNTIME/run/desired-state")" == on ]]
[[ "$(cat "$RUNTIME/run/sing-box.pid")" == "$ENGINE_BEFORE_EXPIRY" ]]
# A stuck privileged validation must be killed before the same deadline.
/usr/bin/printf '{"delay_check":true}\n' > "$CONTROL/pending-config.json"
send_action_expect reload error 2
/usr/bin/ruby - "$LAST_COMMAND_RESPONSE" "$LAST_COMMAND_EXPIRY" <<'RUBY'
abort 'Privileged configuration check outlived the operation' unless File.mtime(ARGV[0]).to_f * 1000 < ARGV[1].to_i
RUBY
[[ "$(cat "$RUNTIME/run/sing-box.pid")" == "$ENGINE_BEFORE_EXPIRY" ]]
# A short remaining budget still restores configuration before rejecting reload.
/usr/bin/printf '{"delay_run":true}\n' > "$CONTROL/pending-config.json"
# Six seconds forces the delayed new runtime to fail while allowing fixed
# rollback work on CI. Use response mtime so test polling/tool startup is excluded.
send_action_expect reload error 6
/usr/bin/ruby - "$LAST_COMMAND_RESPONSE" "$LAST_COMMAND_EXPIRY" <<'RUBY'
abort 'Rollback received a fresh operation budget' unless File.mtime(ARGV[0]).to_f * 1000 < ARGV[1].to_i
RUBY
if /usr/bin/grep -q delay_run "$RUNTIME/config.json"; then
  echo 'Deadline rejection did not restore the prior configuration' >&2
  exit 1
fi
wait_for_file_value "$CONTROL/runtime-status" "running"
/usr/bin/printf '{"fail_run":true}\n' > "$CONTROL/pending-config.json"
send_action_expect reload error
wait_for_file_value "$CONTROL/runtime-status" "running"
[[ -f "$CONTROL/last-error.log" ]]
/usr/bin/grep -q 'Controller status:' "$CONTROL/last-error.log"
if /usr/bin/grep -q 'fail_run' "$RUNTIME/config.json"; then
  echo "Failed configuration was not rolled back." >&2
  exit 1
fi

echo "controller protocol: ok"
send_action off
/bin/rm "$RUNTIME/network-ready"
send_action_expect on error
wait_for_file_value "$CONTROL/runtime-status" "waiting for network"
[[ "$(cat "$CURRENT_DNS")" == "198.18.0.2" ]]
send_action off
[[ "$(cat "$CURRENT_DNS")" == "9.9.9.9" ]]
/usr/bin/touch "$RUNTIME/network-ready"
/bin/sleep 5.5
wait_for_file_value "$CONTROL/runtime-status" "stopped"
[[ ! -f "$RUNTIME/run/sing-box.pid" ]]
send_action on
wait_for_file_value "$CONTROL/runtime-status" "running"
send_action off
/bin/cp "$TEST_DIR/config.json" "$CONTROL/pending-config.json"
send_action reload
wait_for_file_value "$CONTROL/runtime-status" "stopped"
wait_for_file_value "$RUNTIME/run/desired-state" "off"
[[ ! -e "$RUNTIME/xray.json" && ! -e "$RUNTIME/run/xray.pid" ]]
send_action reset
[[ ! -e "$RUNTIME/config.json" ]]
[[ ! -e "$CONTROL/config-sha256" ]]
[[ ! -e "$CONTROL/last-error.log" ]]
send_action_expect on error
wait_for_file_value "$RUNTIME/run/desired-state" "on"
wait_for_file_value "$CONTROL/runtime-status" "waiting to retry"
START_FAILURE_COUNT="$(/usr/bin/grep -c 'VPN start failed' "$RUNTIME/vpn.log")"
/bin/sleep 1.5
[[ "$(/usr/bin/grep -c 'VPN start failed' "$RUNTIME/vpn.log")" -gt "$START_FAILURE_COUNT" ]]
[[ "$(/usr/bin/wc -c < "$RUNTIME/vpn.log" | /usr/bin/tr -d '[:space:]')" -le 3000000 ]]
[[ "$(/usr/bin/wc -c < "$RUNTIME/vpn.error.log" | /usr/bin/tr -d '[:space:]')" -le 3000000 ]]
echo "controller: unexpected exits are published; reload preserves off state; reset removes credentials; retries persist and logs are bounded"
